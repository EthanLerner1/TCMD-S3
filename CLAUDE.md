# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Total Commander **WFX (file system) plugin**, written in Delphi/Object Pascal, that mounts Amazon S3 as a browsable file system. Compiles to `.wfx` (Win32) and `.wfx64` (Win64) DLLs. Requires RAD Studio 11 (Delphi 22.0) — the S3 client is Embarcadero's built-in `Data.Cloud.AmazonAPI`, so there are no external package dependencies to fetch.

## Build & test

- **Build release DLLs:** `build/build.cmd` — sets `DELPHI_BIN` to `C:\Program Files (x86)\Embarcadero\Studio\22.0\bin`, runs `rsvars.bat`, then `msbuild source/S3.dproj` for Win32 and Win64, copies outputs from `../bin/` to `release/`, and zips a distributable. Edit the hardcoded `DELPHI_BIN` path and `version` var in that file if they drift.
- **Build one platform manually:** `msbuild source/S3.dproj /t:Build /p:Config=Release /p:Platform=Win64` (after `rsvars.bat`). Output lands in `bin/` (gitignored).
- **Tests:** DUnitX console runner at `test/S3.Tests.dproj`. Build it (`msbuild test/S3.Tests.dproj`) and run the resulting exe. Fixtures live in `test/Wfx.Plugin.S3.tests.pas`; add a `[Test]` method to `S3PluginFixture` and it auto-registers.

## Architecture

Three layers, entry to implementation:

1. **`Wfx.Plugin.ExportProcs.pas`** — the DLL's exported `Fs*W` functions that Total Commander calls (`FsFindFirstW`, `FsGetFileW`, `FsPutFileW`, etc.). Every export is a thin `stdcall` shim that forwards to a single `Plugin: IWfxPlugin` instance. `S3.dpr` lists which of these get `exports`ed. This layer is pure plumbing — put logic in the plugin classes, not here.
2. **`Wfx.Plugin.Base.pas` (`TWFXPlugin`)** — abstract base implementing `IWfxPlugin` (defined in `Wfx.Plugin.intf.pas`). Holds the TC callbacks (progress/log/request procs), manages the `FFileList: TList<TFileInfo>` cursor that backs the `FindFirst`/`FindNext` iteration protocol, and provides no-op virtual defaults for every optional WFX operation so subclasses override only what they support.
3. **`Wfx.Plugin.S3.pas` (`TS3Plugin`)** — the actual S3 logic. Instantiated via the `globalPluginFactory` set in its `initialization` section (called from `DLLEntryPoint` on process attach).

### Two things worth understanding before editing S3 logic

- **`PluginMode` state machine** (`TS3Plugin`): `pmInit → pmPickProfile → pmPickBucket → pmShowFolderContents`. `FindFirstFile` branches on the current mode to decide what the "directory listing" contains — AWS profiles, buckets, or actual S3 objects. Navigating to root (`\`) resets back toward bucket-picking. The `[PICK AWS PROFILE]` pseudo-file is an `ftAction` entry whose `OnExecute` closure switches modes and triggers a TC refresh. Directory listings are built imperatively here, not fetched lazily per-item.

- **Path translation** (`Wfx.Plugin.S3.Path.pas`, `TS3TcPath`): Total Commander uses Windows-style backslash paths (`\bucket\folder\file`); S3 uses forward-slash keys with no leading bucket. Every S3 call routes a TC path through this record — `GetBucketName`, `StripKnownBucket`, `GetPrefix`, `IsBucket`/`IsRoot`/`IsS3Object`. If a path-handling bug appears, it is almost certainly here or in the caller's choice of which strip function to use. `SetBucketName` keeps `TS3TcPath.BucketName` in sync.

### Other notes

- Credentials come from `~/.aws/credentials` (INI, read via `TIniFile`), keyed by profile name; region defaults to `eu-west-1`. No SDK config beyond that file.
- S3 has no native rename — `RenMovFile` implements it as copy-then-delete (only deletes the source when old and new buckets match).
- `LogDebug` only emits when a debugger is attached (`OutputDebugString`), so use DebugView/IDE to see plugin logs.
- Known gaps (see README roadmap): deleting folders, permissions, metadata, and object version history are not implemented.
