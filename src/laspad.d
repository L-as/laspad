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
import std.algorithm.searching;

import core.thread;
import core.stdc.stdlib      : exit;
version(Posix) {
	import core.sys.posix.unistd : link;
	void copy(string a, string b) {
		if(link(a.toStringz, b.toStringz)) throw new FileException(b, "Could not link '%s' and '%s'!".format(a, b));
	}
}

import toml;

import steam_api;
import mdbbconverter;

immutable config = "laspad.toml";
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

void ensure(bool success, string message) {
	if(!success) {
		stderr.writeln(message);
		exit(1);
	}
}

void needconfig() {
	version(Posix) {
		while(getcwd != "/" && !config.exists) chdir("..");
	}
	config.exists.ensure("This is not a laspad project! Please rename your config.toml to laspad.toml if you haven't done that yet.");
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

immutable source_paths        = ["src", "output", "source"]; // All are traversed, prioritisation.
immutable blacklisted_endings = [".psd", ".xcf"];            // Mods will most likely not use these.
void iterate_entries   (string loc, void delegate(string loc, string entry) func) {
	loc = loc.buildNormalizedPath;

	static void iterate(string loc, void delegate(string loc, string entry) func) {
		foreach(entry; loc.dirEntries(SpanMode.breadth)) {
			if(!blacklisted_endings.canFind(entry.extension)) {
				func(loc, entry[loc.length+1 .. $]);
			}
		}
	}

	ubyte found = 0;
	foreach(src; source_paths) {
		auto rel_src = loc.buildPath(src);
		if(rel_src.exists) {
			found += 1;
			iterate(rel_src, func);
		}
	}

	bool laspad_mod = loc.buildPath("laspad.toml").exists;

	if(found > 1) {
		stderr.writefln("WARNING: %s has %s source folders!", loc, found);
	} else if(found == 0) {
		stderr.writefln("WARNING: %s has no source folders!", loc, found);
		if(!laspad_mod) iterate(loc, func);
	}

	if(laspad_mod) {
		auto dependencies = loc.buildPath("dependencies");
		if(dependencies.exists) foreach(dependency; dependencies.dirEntries(SpanMode.shallow)) {
			iterate_entries(dependency, func);
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
		append(".gitignore", "compiled\n");

		config.write(default_config);
		break;
	case "necessitate":
		needconfig;
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
		needconfig;
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
		needconfig;
		auto s = stash();
		spawnProcess(["git", "submodule", "sync", "--recursive"]).ensure;
		spawnProcess(["git", "submodule", "update", "--init", "--remote", "--recursive"]).ensure;
		spawnProcess(["git", "commit",    "-am",     "Updated dependencies"]).wait;
		break;
	case "compile":
		needconfig;
		if(exists("compiled")) rmdirRecurse("compiled");
		mkdir("compiled");

		iterate_entries(".", (loc, entry) {
			auto dst = buildPath("compiled", entry);
			if(dst.exists) return;

			auto src = loc.buildPath(entry);
			if(src.isDir) mkdir(dst);
			else          copy(src, dst);
		});
		break;
	case "publish":
		needconfig;
		if(!SteamAPI_Init()) exit(1);

		auto remote = SteamRemoteStorage();
		auto utils  = SteamUtils();

		(remote || utils).ensure("Could not load utils or remote APIs!");

		auto variation = args.length < 3 ? "master" : args[2];
		auto toml_root = config.readText.parseTOML;
		if(variation !in toml_root) {
			stderr.writeln("Not a valid variation!");
			exit(1);
		}

		auto toml      = toml_root[variation].table;

		const(char*)[] delendus;
		scope(exit) foreach(file; delendus) {
			Thread.sleep(500.msecs); // Steam isn't always done immediately for some stupid reason...
			SteamAPI_ISteamRemoteStorage_FileDelete(remote, file);
		}
		ulong          modid;
		int            callback_type;
		SteamAPICall_t apicall;
		if (exists(".modid." ~ variation)) {
			(!!("name"            in toml)).ensure("Please supply a name field!");
			(!!("tags"            in toml)).ensure("Please supply tags!");
			(!!("autodescription" in toml)).ensure("Please supply whether to use the automatic description generator!");
			(!!("description"     in toml)).ensure("Please supply a path to the description file!");
			(!!("preview"         in toml)).ensure("Please supply a path to the preview file!");
			auto name             = toml["name"].str;
			auto tags             = toml["tags"].array;
			auto autodescription  = toml["autodescription"].boolean;

			auto description_path = toml["description"].str;
			auto description      = description_path.extension == ".md" ?
				toml["description"].str.readText.markdown_to_bbcode :
				toml["description"].str.readText;

			auto preview          = cast(byte[])toml["preview"].str.read;


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
							auto workshop_url = "http://steamcommunity.com/sharedfiles/filedetails/?id=%s".format(dependency_modid.to!ulong(16));
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

			iterate_entries(".", (loc, entry) {
				auto src = loc.buildPath(entry);
				if(src.isDir) return;

				if(entry == ".modinfo") {
					writeln("Skipped .modinfo!");
					return;
				}
				auto member               = new ArchiveMember;
				static if(dirSeparator   != "/") {
					member.name           = entry.tr(dirSeparator, "/");
				} else {
					member.name           = entry;
				}
				member.expandedData       = cast(ubyte[])src.read;
				member.compressionMethod  = CompressionMethod.deflate;
				file.addMember(member);
			});

			auto modinfo         = new ArchiveMember;
			modinfo.name         = ".modinfo";
			modinfo.expandedData = ("name=\"" ~ name ~"\"").representation.dup;
			file.addMember(modinfo);

			auto data         = cast(byte[])file.build;

			auto filename     = "ns2mod.%s.%s.zip".format(name, variation).toStringz;
			auto preview_name = "ns2mod.%s.%s.preview.jpg".format(name, variation).toStringz;
			SteamAPI_ISteamRemoteStorage_FileWrite(remote, filename, data.ptr, cast(int)data.length).ensure(
				"Could not write zip file to remote storage! Please check https://partner.steamgames.com/doc/api/ISteamRemoteStorage#FileWrite for possible reasons."
			);
			delendus ~= filename;
			if(preview.length != 0) {
				SteamAPI_ISteamRemoteStorage_FileWrite(remote, preview_name, preview.ptr, cast(int)preview.length).ensure(
					"Could not write preview file to remote storage! Please check https://partner.steamgames.com/doc/api/ISteamRemoteStorage#FileWrite for possible reasons."
				);
				delendus ~= preview_name;
			}

			const(char*)[] strings;
			foreach(tag; tags) {
				strings ~= tag.str.toStringz;
			}
			auto steam_tags = Strings(strings.ptr, cast(int)strings.length);

			auto update = SteamAPI_ISteamRemoteStorage_CreatePublishedFileUpdateRequest(remote, modid);
			SteamAPI_ISteamRemoteStorage_UpdatePublishedFileFile(remote, update, filename).ensure("Could not publish file!");
			if(preview.length != 0) {
				SteamAPI_ISteamRemoteStorage_UpdatePublishedFilePreviewFile(remote, update, preview_name).ensure("Could not publish preview!");
			}
			SteamAPI_ISteamRemoteStorage_UpdatePublishedFileDescription(remote, update, description.toStringz).ensure("Could not publish description!");
			SteamAPI_ISteamRemoteStorage_UpdatePublishedFileSetChangeDescription(remote, update, commit.toStringz).ensure("Could not publish change log!");
			SteamAPI_ISteamRemoteStorage_UpdatePublishedFileTags(remote, update, &steam_tags).ensure("Could not publish tags!");
			SteamAPI_ISteamRemoteStorage_UpdatePublishedFileTitle(remote, update, name.toStringz).ensure("Could not publish title!");
			apicall = SteamAPI_ISteamRemoteStorage_CommitPublishedFileUpdate(remote, update);

			callback_type = 1316;
		} else {
			auto dummy = "ns2mod.dummy.dummy.dummy".toStringz;
			byte[] data = [0];
			SteamAPI_ISteamRemoteStorage_FileWrite(remote, dummy, data.ptr, cast(int)data.length).ensure(
				"Could not write dummy file to remote storage! Please check https://partner.steamgames.com/doc/api/ISteamRemoteStorage#FileWrite for possible reasons."
			);
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

		if(result.result != Result.OK)
			exit(1);

		break;
	case "help":
		writeln(help);
		break;
	default:
		stderr.writeln("Not a valid command!");
		goto case "help";
	}
}
