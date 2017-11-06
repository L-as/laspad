import std.stdio;
import std.file;
import std.process;
import std.array;
import std.path;
import std.string;
import std.zip;
import std.range;
import std.format;
import std.conv;
import std.exception;

import core.stdc.stdlib      : exit;
version(Posix) {
	import core.sys.posix.unistd : link;
	void copy(string a, string b) {
		link(a.toStringz, b.toStringz);
	}
}

import toml;

import steam_api;

immutable config = "config.toml";
immutable help                = import("help.txt");
immutable default_config      = import(config);

alias write = std.file.write;

void ensure(Pid pid) {
	auto err = pid.wait;
	if(err) {
		stderr.writefln("laspad encountered an error!");
		exit(1);
	}
}

auto stash() {
	struct S {
		bool changed;
		this(bool changed) {
			this.changed = changed;
			if(changed) {
				spawnProcess(["git", "stash"]).ensure;
			}
		}
		~this() {
			if(changed) {
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
			copy(entry, path);
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
			foreach(part; split[3 .. $]) if(part[0] == '.') continue outer;
			auto path = buildPath("output", split[3 .. $].join(dirSeparator));

			if(entry.isDir) {
				if(!path.exists) path.mkdir;
			} else {
				copy(entry, path);
			}
		}
	}
}

void main(string[] args) {
	auto operation = args.length > 1 ? args[1] : "";

	switch(operation) {
	case "init":
		if(config.exists) {
			stderr.writeln("Mod already present!");
			exit(1);
		}
		if(!exists("src")) {
			mkdir("src");
		}
		append(".gitignore", "output\noutput.zip\n");

		config.write(default_config);
		break;
	case "necessitate":
		if(args.length < 3) {
			stderr.writeln("Syntax: laspad necessitate <git repo URLs>");
			exit(1);
		}
		if(!exists("dependencies")) mkdir("dependencies");
		auto s = stash();
		foreach(repo; args[2 .. $]) {
			spawnProcess(["git", "submodule", "add", repo], null, Config.none, "dependencies").ensure;
		}
		spawnProcess(["git", "commit", "-m", "Added dependencies '" ~ args[2 .. $].join(' ') ~ "'"]).ensure;
		break;
	case "denecessitate":
		if(args.length < 3) {
			stderr.writeln("Syntax: laspad denecessitate <git repo names>");
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
	case "publish":
		if(!SteamAPI_Init()) exit(1);

		auto remote = SteamRemoteStorage();
		auto utils  = SteamUtils();

		if(!remote || !utils) {
			stderr.writeln("Could not load utils or remote apis!");
			exit(1);
		}

		auto variation = args.length < 3 ? "master" : args[2];
		auto toml      = config.readText.parseTOML[variation].table;

		const(char*)[] delendus;
		scope(exit) foreach(file; delendus) {
			SteamAPI_ISteamRemoteStorage_FileDelete(remote, file);
		}
		ulong          modid;
		int            callback_type;
		SteamAPICall_t apicall;
		if (exists(".modid." ~ variation)) {
			compile;

			auto name            = toml["name"].str;
			auto tags            = toml["tags"].array;
			auto autodescription = toml["autodescription"].boolean;
			auto description     = toml["description"].str.readText;
			auto preview         = cast(byte[])toml["preview"].str.read;

			auto commit = "git commit: %s".format(execute(["git", "rev-parse", "HEAD"]).output);
			modid = readText(".modid." ~ variation).to!ulong(16);

			if(autodescription) {
				auto old_description = description;
				description = "[b]Mod ID: %X[/b]\n\n".format(modid);
				auto gitremote = execute(["git", "remote", "get-url", "origin"]);
				if(!gitremote.status) {
					auto url = gitremote.output.strip.dup;
					if(url.startsWith("git@")) { // ssh
						url = url.chompPrefix("git@");
						url[url.indexOf(':')] = '/';
						url = "https://" ~ url;
					}
					url = url.chomp(".git");
					description ~= "[b][url=%s]git repository[/url][/b]\ncurrent %s\n\n".format(url, commit);
				}
				auto shortlog = execute(["git", "shortlog", "-sn"]);
				if(!shortlog.status) {
					description ~= "Authors: (commits, author) [code]\n%s[/code]\n\n".format(shortlog.output);
				}
				auto submodules = execute(["git", "config", "-f", ".gitmodules", "--get-regexp", "submodule\\.dependencies/.*\\.url"]);
				if(!submodules.status) {
					description ~= "Mods included: [list]\n";
					foreach(line; submodules.output.lineSplitter) {
						auto split = line.split;
						auto dependency = split[0]["submodule.dependencies/".length .. $-".url".length];
						auto url        = split[1];
						try {
							auto dependency_modid = readText("dependencies/"~dependency~"/.modid.master");
							auto workshop_url = "http://steamcommunity.com/sharedfiles/filedetails/?id=%s".format(dependency_modid.to!ulong);
							description ~= "  [*] [url=%s]%s[/url] ([url=%s]Workshop link[/url])".format(url, dependency, workshop_url);
						} catch(FileException e) {
							description ~= "  [*] [url=%s]%s[/url]".format(url, dependency);
						}
					}
					description ~= "[/list]\n\n";
				}
				description ~= old_description;
			}

			auto file            = new ZipArchive;

			auto modinfo         = new ArchiveMember;
			modinfo.name         = ".modinfo"; modinfo.expandedData = ("name=\"" ~ name ~"\"").representation.dup;
			file.addMember(modinfo);

			foreach(entry; dirEntries("output", SpanMode.depth)) {
				if(entry.isDir) continue;
				auto member         = new ArchiveMember;
				member.name         = entry.pathSplitter.drop(1).buildPath;
				member.expandedData = cast(ubyte[])entry.read;
				file.addMember(member);
			}

			auto data         = cast(byte[])file.build;

			auto filename     = "ns2mod.%s.%s.zip".format(name, variation).toStringz;
			auto preview_name = "ns2mod.%s.%s.preview.jpg".format(name, variation).toStringz;
			if(!SteamAPI_ISteamRemoteStorage_FileWrite(remote, filename, data.ptr, cast(int)data.length)) {
				stderr.writeln("Could not write zip file to remote storage! Please check https://partner.steamgames.com/doc/api/ISteamRemoteStorage#FileWrite for possible reasons.");
				exit(1);
			}
			delendus ~= filename;
			if(!SteamAPI_ISteamRemoteStorage_FileWrite(remote, preview_name, preview.ptr, cast(int)preview.length)) {
				stderr.writeln("Could not write preview file to remote storage! Please check https://partner.steamgames.com/doc/api/ISteamRemoteStorage#FileWrite for possible reasons.");
				exit(1);
			}
			delendus ~= preview_name;

			const(char*)[] strings;
			foreach(tag; tags) {
				strings ~= tag.str.toStringz;
			}
			auto steam_tags = Strings(strings.ptr, cast(int)strings.length);

			auto update = SteamAPI_ISteamRemoteStorage_CreatePublishedFileUpdateRequest(remote, modid);
			SteamAPI_ISteamRemoteStorage_UpdatePublishedFileFile(remote, update, filename).enforce;
			SteamAPI_ISteamRemoteStorage_UpdatePublishedFilePreviewFile(remote, update, preview_name).enforce;
			SteamAPI_ISteamRemoteStorage_UpdatePublishedFileDescription(remote, update, description.toStringz).enforce;
			SteamAPI_ISteamRemoteStorage_UpdatePublishedFileSetChangeDescription(remote, update, commit.toStringz).enforce;
			SteamAPI_ISteamRemoteStorage_UpdatePublishedFileTags(remote, update, &steam_tags).enforce;
			SteamAPI_ISteamRemoteStorage_UpdatePublishedFileTitle(remote, update, name.toStringz).enforce;
			apicall = SteamAPI_ISteamRemoteStorage_CommitPublishedFileUpdate(remote, update);

			callback_type = 1316;
		} else {
			auto dummy = "ns2mod.dummy.dummy.dummy".toStringz;
			byte[] data = [0];
			if(!SteamAPI_ISteamRemoteStorage_FileWrite(remote, dummy, data.ptr, cast(int)data.length)) {
				stderr.writeln("Could not write dummy file to remote storage! Please check https://partner.steamgames.com/doc/api/ISteamRemoteStorage#FileWrite for possible reasons.");
				exit(1);
			}
			delendus ~= dummy;

			auto tags = Strings(null, 0);
			apicall = SteamAPI_ISteamRemoteStorage_PublishWorkshopFile(remote,
				dummy,
				dummy,
				4920,
				dummy,
				dummy,
				Visibility.Public,
				&tags,
				FileType.Community,
			);

			callback_type = 1309;
		}

		bool failure;
		while(!SteamAPI_ISteamUtils_IsAPICallCompleted(utils, apicall, &failure)) {}
		if(failure) {
			stderr.writeln("Failed to publish mod!");
			exit(1);
		}

		auto result = RemoteStoragePublishFileResult();

		SteamAPI_ISteamUtils_GetAPICallResult(utils, apicall, &result, result.sizeof, callback_type, &failure);
		if(failure) {
			stderr.writeln("Failed to publish mod!");
			stderr.writeln("API call failure reason: ", SteamAPI_ISteamUtils_GetAPICallFailureReason(utils, apicall));
		}

		if(result.accept_agreement) stderr.writeln("You have to accept the steam agreement!");
		writeln("Response from steam: ", result.result);

		if(!failure && result.result == Result.OK && !modid) {
			auto id = result.id.to!string(16);
			writefln("Mod ID: %s (%s)", id, result.id);
			write(".modid." ~ variation, id);
			goto case "publish";
		}

		break;
	case "help":
		writeln(help);
		break;
	default:
		stderr.writeln("Not a valid command!");
		goto case "help";
	}
}
