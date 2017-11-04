import std.stdio;

import steam_api;

int main(string[] args) {
	if (!SteamAPI_Init()) return 1;

	auto remote = SteamRemoteStorage();
	auto utils  = SteamUtils();

	if (!remote || !utils) {
		stderr.writeln("Could not load utils or remote apis!");
		return 2;
	}

	if (args.length < 2) {
		stderr.writeln("All parameters were not supplied!");
		return 3;
	}
	auto name = args[1];

	return 0;
}
