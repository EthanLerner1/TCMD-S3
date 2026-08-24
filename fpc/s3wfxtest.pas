program s3wfxtest;
{$mode objfpc}{$H+}
// Drives the compiled .wfx64 through the WFX protocol, like Total Commander does.
uses windows, SysUtils, Classes;

type
  TFindFirst = function(Path: PWideChar; var fd: TWin32FindDataW): THandle; stdcall;
  TFindNext  = function(Hdl: THandle; var fd: TWin32FindDataW): LongBool; stdcall;
  TFindClose = function(Hdl: THandle): Integer; stdcall;
  TGetFile   = function(Remote, Local: PWideChar; Flags: Integer; Info: Pointer): Integer; stdcall;
  TInitW     = function(nr: Integer; a,b,c: Pointer): Integer; stdcall;

var
  h: HMODULE;
  FindFirst_: TFindFirst;
  FindNext_: TFindNext;
  FindClose_: TFindClose;
  GetFile_: TGetFile;
  InitW_: TInitW;
  gCalls: Integer = 0;
  gAbort: Boolean = False;

// Stand-in for Total Commander's progress callback.
function MyProgress(PluginNr: Integer; Source, Target: PWideChar;
  Percent: Integer): Integer; stdcall;
begin
  Inc(gCalls);
  writeln('    progress: ', Percent, '%');
  if gAbort then Result := 1 else Result := 0;   // 1 = user wants to abort
end;

function NameOf(const fd: TWin32FindDataW): string;
begin
  Result := WideString(PWideChar(@fd.cFileName[0]));
end;

procedure ListDir(const path: string);
var fd: TWin32FindDataW; hf: THandle; more: Boolean; tag: string; n: Integer; szv: Int64;
begin
  writeln('--- listing "', path, '" ---');
  hf := FindFirst_(PWideChar(WideString(path)), fd);
  if hf = THandle(INVALID_HANDLE_VALUE) then begin writeln('  (empty)'); Exit; end;
  n := 0;
  more := True;
  while more do
  begin
    if (fd.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then tag := '[dir] '
    else tag := '[file]';
    szv := (Int64(fd.nFileSizeHigh) shl 32) or Int64(fd.nFileSizeLow);
    writeln('  ', tag, ' ', NameOf(fd), '  ', szv);
    Inc(n);
    more := FindNext_(hf, fd);
  end;
  FindClose_(hf);
  writeln('  (', n, ' entries)');
end;

var
  h1: HMODULE; r, sz: Integer; local: string; fs: TFileStream;
begin
  h := LoadLibrary('WvN-S3-fpc.wfx64');
  if h = 0 then begin writeln('LoadLibrary failed: ', GetLastError); Halt(2); end;

  InitW_     := TInitW(GetProcAddress(h, 'FsInitW'));
  FindFirst_ := TFindFirst(GetProcAddress(h, 'FsFindFirstW'));
  FindNext_  := TFindNext(GetProcAddress(h, 'FsFindNextW'));
  FindClose_ := TFindClose(GetProcAddress(h, 'FsFindClose'));
  GetFile_   := TGetFile(GetProcAddress(h, 'FsGetFileW'));

  InitW_(0, @MyProgress, nil, nil);                // register progress callback

  ListDir('\');                                    // buckets
  ListDir('\hydra-build\');                        // bucket root
  ListDir('\hydra-build\hydra-build\');            // folder named like the bucket (the bug)

  // Big streaming download (8.7 MB): proves constant memory + progress firing.
  local := GetTempDir + 'wfxbig.bin';
  gCalls := 0; gAbort := False;
  writeln('--- FsGetFileW streaming download (8.7 MB) ---');
  r := GetFile_(
    PWideChar(WideString('\hydra-build\hydra-build\linux-build\models\RTX40\features\voice\DeepFilterNet3.pt')),
    PWideChar(WideString(local)), 0, nil);
  sz := 0;
  if FileExists(local) then
  begin fs := TFileStream.Create(local, fmOpenRead); try sz := fs.Size; finally fs.Free; end; end;
  writeln('  result=', r, '  bytes=', sz, '  (expected 0 / 8714073)  progress-calls=', gCalls);
  if (r = 0) and (sz = 8714073) and (gCalls > 0) then writeln('  STREAM+PROGRESS OK')
  else writeln('  FAIL');

  // Abort mid-download: callback returns 1; expect USERABORT (5) + file removed.
  local := GetTempDir + 'wfxabort.bin';
  gCalls := 0; gAbort := True;
  writeln('--- FsGetFileW abort test ---');
  r := GetFile_(
    PWideChar(WideString('\hydra-build\hydra-build\linux-build\models\RTX40\features\voice\DeepFilterNet3.pt')),
    PWideChar(WideString(local)), 0, nil);
  writeln('  result=', r, '  (expected 5=USERABORT)  file-exists=', FileExists(local));
  if (r = 5) and (not FileExists(local)) then writeln('  ABORT OK') else writeln('  ABORT FAIL');

  FreeLibrary(h);
end.
