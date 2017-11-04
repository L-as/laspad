import std.stdio;
import std.file;
import std.process;
import std.array;
import std.path;
import std.string;

import core.stdc.stdlib      : exit;
import core.sys.posix.unistd : link;

import toml;

import steam_api;

alias write = std.file.write;

void ensure(Pid pid) {
	auto err = pid.wait;
	if (err) {
		stderr.writefln("ns2modder encountered an error!");
		exit(1);
	}
}

auto stash() {
	struct S {
		bool changed;
		this(bool changed) {
			this.changed = changed;
			if (changed) {
				spawnProcess(["git", "stash"]).ensure;
			}
		}
		~this() {
			if (changed) {
				spawnProcess(["git", "stash", "pop", "--index"]).ensure;
			}
		}
	}

	return S(!!spawnProcess(["git", "diff-index", "--quiet", "HEAD", "--"]).wait);
}

void compile() {
	if(exists("output")) rmdirRecurse("output");
	mkdir("output");

	foreach(string entry; dirEntries("src", SpanMode.breadth)) {
		//relative path within the mod itself
		auto split = entry.split(dirSeparator);
		split[0] = "output";
		auto path  = split.join(dirSeparator);

		if(entry.isDir) {
			if(!path.exists) path.mkdir;
		} else {
			version(Posix) {
				link(entry.toStringz, path.toStringz);
			} else {
				copy(entry, path);
			}
		}
	}

	if(exists("dependencies")) foreach(string dependency; dirEntries("dependencies", SpanMode.shallow)) {
		auto src =
			chainPath(dependency, "src").exists    ? buildPath(dependency, "src")    :
			chainPath(dependency, "output").exists ? buildPath(dependency, "output") :
			chainPath(dependency, "source").exists ? buildPath(dependency, "source") :
			buildPath(dependency, ".");

		outer:
		foreach(string entry; src.dirEntries(SpanMode.breadth)) {
			auto split = entry.split(dirSeparator);
			foreach(part; split[3 .. $]) if (part[0] == '.') continue outer;
			auto path = buildPath("output", split[3 .. $].join(dirSeparator));

			if(entry.isDir) {
				if(!path.exists) path.mkdir;
			} else {
				version(Posix) {
					link(entry.toStringz, path.toStringz);
				} else {
					copy(entry, path);
				}
			}
		}
	}
}

immutable config = "config.toml";
immutable help                = import("help.txt");
immutable default_config      = import(config);

void main(string[] args) {
	auto operation = args.length > 1 ? args[1] : "";

	switch(operation) {
	case "init":
		if (config.exists) {
			stderr.writeln("Mod already present!");
			exit(1);
		}
		if (!exists("src")) {
			mkdir("src");
		}
		append(".gitignore", "output\n");

		config.write(default_config);
		break;
	case "necessitate":
		if (args.length < 3) {
			stderr.writeln("Syntax: ns2modder necessitate <git repo URLs>");
			exit(1);
		}
		if (!exists("dependencies")) mkdir("dependencies");
		auto s = stash();
		foreach(repo; args[2 .. $]) {
			spawnProcess(["git", "submodule", "add", repo], null, Config.none, "dependencies").ensure;
		}
		spawnProcess(["git", "commit", "-m", "Added dependencies '" ~ args[2 .. $].join(' ') ~ "'"]).ensure;
		break;
	case "denecessitate":
		if (args.length < 3) {
			stderr.writeln("Syntax: ns2modder necessitate <git repo names>");
			exit(1);
		}
		auto s = stash();
		foreach(repo; args[2 .. $]) {
			spawnProcess(["git", "rm",                                              "dependencies/" ~ repo]).ensure;
			spawnProcess(["git", "config", "--local", "--remove-section", "submodule.dependencies/" ~ repo]).ensure;
		}
		spawnProcess(["git", "commit", "-m", "Removed dependencies '" ~ args[2 .. $].join(' ') ~ "'"]).ensure;
		break;
	case "update":
		auto s = stash();
		spawnProcess(["git", "submodule", "init"]).ensure;
		spawnProcess(["git", "submodule", "sync"]).ensure;
		spawnProcess(["git", "submodule", "update", "--remote"]).ensure;
		spawnProcess(["git", "commit",    "-am",     "Updated dependencies"]).wait;
		break;
	case "compile":
		compile;
		break;
	case "help":
		writeln(help);
		break;
	default:
		stderr.writeln("Not a valid command!");
		goto case "help";
	}

	/*
	if (!SteamAPI_Init()) return 1;

	auto remote = SteamRemoteStorage();
	auto utils  = SteamUtils();

	if (!remote || !utils) {
		stderr.writeln("Could not load utils or remote apis!");
		exit(1);
	}
	*/
}
