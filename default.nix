with import <nixpkgs> {};
stdenv.mkDerivation {
  name = "mullvad-netns";
  src = ./.;
  installFlags = [ "PREFIX=$(out)" "BINDIR=$(out)/bin" "SYSCONFDIR=$(out)/etc" ];

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    wrapProgram $out/bin/mullvad-netns \
       --prefix PATH : "${lib.makeBinPath [ coreutils jq nftables iproute2 curl util-linux wireguard-tools ]}"
  '';
}
