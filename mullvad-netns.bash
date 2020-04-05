#!/bin/bash
#
# Author: Patrick McLean <chutzpah@gentoo.org>
#
# SPDX-License-Identifier: GPL-2.0+

CONFIG_FILE="/etc/wireguard/mullvad/config"

# all these variables can be overriden in the config file
MULLVAD_PORT=51820
RELAYS_URI="https://api.mullvad.net/public/relays/wireguard/v1/"
MULLVAD_API_URI="https://api.mullvad.net/wg/"

# the default country to select a server from, list of available countries is available with
# curl https://api.mullvad.net/public/relays/wireguard/v1/ | jq  ".countries[].name"
# defaults to USA
COUNTRY="usa"

# the default city to select a server from, list of available cities withing a country available with
#curl -s https://api.mullvad.net/public/relays/wireguard/v1/ | jq ".countries[] | select(.name == \"${COUNTRY}\") | .cities[].name"
# defaults to any server in California
CITY=", ca"

# file name to find the account in
ACCOUNT_FILENAME="/etc/wireguard/mullvad/account"

# directory to store keys in
WG_KEYFILE="/etc/wireguard/mullvad/privatekey"

# location of cache of servers list
SERVERS_CACHE="/var/lib/misc/mullvad-servers.json"

# how often to refresh cache of mullvad servers
SERVERS_CACHE_MAX_AGE="1 day"

# location to load nftables rules from
NFTABLES_RULESET="/etc/wireguard/mullvad/rules.nft"

# list of nameservers to use inside the netns
NAMESERVERS=(
	"193.138.218.74"
	"1.1.1.1"
	"1.0.0.1"
	"2606:4700:4700::1111"
	"2606:4700:4700::1001"
)

# make sure these are empty
declare -a TEMPFILES=()
unset netns


cleanup() {
	rm -f "${TEMPFILES[@]}"

	# remove the network namespace if it's empty
	[[ -n ${netns} && -z $(ip netns pids "${netns}") ]] && ip netns del "${netns}"
}

_curl() {
	# drop privliges and run curl
	runuser -u nobody -- curl --location --silent --show-error "${@}"
}

_jq() {
	# drop privliges and run jq
	runuser -u nobody -- jq "${@}"
}

mullvad_update_server_list() {
	# atomically update the mullvad server list cache

	TEMPFILES+=("$(mktemp "${SERVERS_CACHE%/*}/.mullvad-servers-XXXXXX.json")") || return
	local tempfile="${TEMPFILES[-1]}"
	_curl "${RELAYS_URI}" | _jq . > "${tempfile}" || { rm -f "${tempfile}"; return 1; }
	mv -f "${tempfile}" "${SERVERS_CACHE}"
}

mullvad_select_random_server() {
	local country="${1:-${COUNTRY}}" city="${2:-${CITY}}"

	if [[ -r ${SERVERS_CACHE} ]]; then
		if [[ $(date -u -r "${SERVERS_CACHE}" +%s) -lt $(date -u --date="-${SERVERS_CACHE_MAX_AGE}" +%s) ]]; then
			mullvad_update_server_list || return
		fi
	else
		mullvad_update_server_list || return
	fi

	local country_select city_select
	[[ -n ${country} ]] && country_select="| select(.name | test(\"${country}\"; \"i\"))"
	[[ -n ${city} ]] && city_select="| select(.name | test(\"${city}\"; \"i\"))"

	local -a server_list
	readarray -t server_list <<< "$(_jq -r "
			(.countries[] ${country_select}
				| (.cities[] ${city_select}
					| (.relays[]
						| [.hostname, .public_key, .ipv4_addr_in, .ipv6_addr_in])
				)
			)
			| flatten
			| join(\"\\t\")" "${SERVERS_CACHE}")" || return

	local server_count="${#server_list[@]}"

	printf -- '%s\n' "${server_list[$((RANDOM % server_count))]}"
}

mullvad_set_local_ips() {
	local pubkey="${1}"
	local account

	if [[ ! -r ${ACCOUNT_FILENAME} ]]; then
		printf -- '%s: Could not find Mullvad account file at "%s"\n' "${progname}" "${ACCOUNT_FILENAME}" >&2
		return 1
	elif ! account="$(< "${ACCOUNT_FILENAME}")"; then
		printf -- '%s: Cound not read Mullvad account from "%s"\n' "${progname}" "${ACCOUNT_FILENAME}" >&2
		return 1
	fi

	if [[ ! ${account} =~ ^((([0-9]{4}[[:space:]]+){3}[0-9]{4})|[0-9]{16})$ ]]; then
		printf -- '%s: Invalid Mullvad account in "%s"\n' "${progname}" "${ACCOUNT_FILENAME}" >&2
		return 1
	fi

	local address
	address="$(_curl "${MULLVAD_API_URI}" \
		-d account="${account// /}" \
		--data-urlencode pubkey="${pubkey}")" || return

	if [[ ! ${address} =~ ^[0-9.]+/[0-9]{1,2},[a-f0-9:]+/[0-9]{1,3}$ ]]; then
		printf -- '%s\n' "${address}" >&2
		return 1
	fi

	IFS=',' read -r local_ipv4 local_ipv6 <<< "${address}" || return
}

get_wireguard_keys() {
	local keyfile="${WG_KEYFILE:-/etc/wireguard/mullvad/privatekey}"
	local keydir="${keyfile%/*}"

	if [[ ! -d ${keydir} ]]; then
		mkdir -p "${keydir}" || return
		chmod 0755 "${keydir}" || return
	fi

	local privatekey pubkey
	if [[ -r ${keyfile} ]]; then
		privatekey="$(<"${keyfile}")" || return
	else
		privatekey=$(set -o pipefail; umask 077; wg genkey | tee "${keyfile}") || return
	fi

	pubkey="$(wg pubkey <<< "${privatekey}")" || return

	printf -- '%s %s\n"' "${privatekey}" "${pubkey}"
}


setup_interface() {
	# script to setup the network namespace
	local -a setup_script=(
		"netns add ${netns}"
		"link add dev ${linkname} type wireguard"
		"link set netns ${netns} ${linkname}"
	)

	# script to run to bring the link up
	local -a linkup_script=(
		"address add ${local_ipv4} dev ${linkname}"
		"address add ${local_ipv6} dev ${linkname}"
		"link set dev lo up"
		"link set dev ${linkname} up"
		"route add default dev ${linkname} scope global"
		"-family inet6 route add default dev ${linkname} scope global"
	)

	# initial setup
	if ! ip -batch - <<< "$(printf '%s\n' "${setup_script[@]}")"; then
		ip link del "${linkname}" 2>/dev/null
		ip netns del "${linkname}" 2>/dev/null
		return 1
	fi

	local endpoint
	if [[ -n ${ipv6} ]]; then
		endpoint="${ipv6_addr}:${MULLVAD_PORT}"
	else
		endpoint="${ipv4_addr}:${MULLVAD_PORT}"
	fi

	# configure the wireguard interface in the netns
	if ! ip netns exec "${netns}" wg set "${linkname}" \
			private-key <(printf -- '%s\n' "${private_key}") \
			peer "${pubkey}" \
			allowed-ips '0.0.0.0/0,::0/0' \
			endpoint "${endpoint}"
	then
		ip netns del "${linkname}"
		return 1
	fi

	# load nftables rules in to netns before bringing up interface
	if [[ -n ${NFTABLES_RULESET} && -r ${NFTABLES_RULESET} ]]; then
		if ! ip netns exec "${netns}" nft -f "${NFTABLES_RULESET}"; then
			ip netns del "${linkname}"
			return 1
		fi
	fi

	# finally bring up the interfaces
	if ! ip -batch - <<< "$(printf -- "netns exec ${netns} ip %s\n" "${linkup_script[@]}")"; then
		ip netns del "${linkname}"
		return 1
	fi

	return 0
}

name_netns() {
	local name="${linkname}" counter=0

	# make sure the network namespace name isn't already in use
	while ip netns list | grep -F -s "${name}"; do
		((counter++))
		name="${linkname}-${counter}"
	done

	# we will use the linkname as the netns for now
	netns="${name}"
}

setup_mount_namespace() {
	TEMPFILES+=("$(mktemp --tmpdir="${TMPDIR:-/tmp}" mullvad-resolvconf-XXXXXX)") || return
	local tempfile="${TEMPFILES[-1]}"

	printf "nameserver %s\n" "${NAMESERVERS[@]}" > "${tempfile}"
	chmod 0644 "${tempfile}" || return

	local run_command
	run_command="$(printf -- '"%s" ' "${@}")"

	local -a mountns_command
	mountns_command=(
		"mount --bind \"${tempfile}\" /etc/resolv.conf"
		"&& exec ip netns exec \"${netns}\""
		"runuser --pty --shell=/bin/bash --command='${run_command}' - ${SUDO_USER}"
	)

	unshare --mount bash -c "${mountns_command[*]}"
}

show_usage() {
	printf 'Usage:\n'
	printf '  %s [options] -- <command>\n' "${progname}"
	printf '  %s <command>\n\n' "${progname}"
	printf 'Run <command> under a network namespace connected to a randomly selected\n'
	printf 'Mullvad server over WireGuard as the only visible network device. This\n'
	printf 'ensures that the command does not have access to the network except through\n'
	printf 'the Mullvad tunnel.\n\nOptions\n'
	printf '  -C, --country <regex>      use only servers from countries matching the\n'
	printf '                               given regular expression\n'
	printf '  -c, --city <regex>         use only servers from cities matching the\n'
	printf '                               given regular expression\n\n'
	printf '  -4, --ipv4                 connect to the Mullvad server over IPv4 (the default)\n'
	printf '  -6, --ipv6                 connect to the Mullvad server over IPv6\n\n'
	printf '  -h, --help                 display this help\n'
}

parse_args() {
	# parse command line options
	local params
	if ! params="$(getopt -o '+C:c:u:46h' -l 'country:,city:,user:,ipv4,ipv6,help' -n "${progname}" -- "${@}")"; then
		show_usage
		return 1
	fi

	eval set -- "${params}"
	while [[ ${#} -gt 0 ]]; do
		case ${1} in
			-C|--country) country=${2}; shift;;
			-c|--city) city="${2}"; shift;;
			-4|--ipv4)
				if [[ -n ${ipv6} ]]; then
					printf '%s: cannot specify both --ipv4 and --ipv6\n' "${progname}" >&2
					return 1
				fi
				ipv4=1
			;;
			-6|--ipv6)
				if [[ -n ${ipv4} ]]; then
					printf '%s: cannot specify both --ipv4 and --ipv6\n' "${progname}" >&2
					return 1
				fi
				ipv6=1
			;;
			-h|--help) show_usage; exit 0;;
			--) shift; break;; 
		esac
		shift
	done

	if [[ -z ${*} ]]; then
		printf '%s: Must specify a command to run\n' "${progname}"
		show_usage
		return 1
	fi

	args=("${@}")
}

main() {
	set -o pipefail
	local progname="${BASH_SOURCE[0]##*/}"
	trap cleanup EXIT

	# source the config file if it exists
	if [[ -r ${CONFIG_FILE} ]]; then
		source "${CONFIG_FILE}" || return
	fi

	if [[ -z ${SUDO_USER} ]]; then
		printf '%s: SUDO_USER is unset, cannot run command as user\n' "${progname}" >&2
		return 1
	fi

	local city country ipv4 ipv6
	local -a args
	parse_args "${@}" || return

	local private_key public_key
	read -r private_key public_key <<< "$(get_wireguard_keys)" || return

	local linkname pubkey ipv4_addr ipv6_addr
	read -r linkname pubkey ipv4_addr ipv6_addr \
		<<< "$(mullvad_select_random_server "${COUNTRY}" "${CITY}")" || return

	local local_ipv4 local_ipv6
	mullvad_set_local_ips "${public_key}" || return

	name_netns || return

	setup_interface || return
	setup_mount_namespace "${args[@]}" || return
}

main "${@}"
