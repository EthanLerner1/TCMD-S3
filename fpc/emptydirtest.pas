program emptydirtest;
{$mode objfpc}{$H+}
// Reproduces "can't enter freshly-created empty folder": mkdir then FsFindFirstW.
uses windows, SysUtils, fpcs3;

type
  TMkDir     = function(Path: PWideChar): BOOL; stdcall;
  TFindFirst = function(Path: PWideChar; var fd: TWin32FindDataW): THandle; stdcall;
  TInitW     = function(nr: Integer; a,b,c: Pointer): Integer; stdcall;

function ReadIni(const Path, Key: string): string;
var f: Text; line, k: string; p: Integer; inDef: Boolean;
begin
  Result := ''; inDef := False;
  if not FileExists(Path) then Exit;
  Assign(f, Path); Reset(f);
  while not Eof(f) do
  begin
    ReadLn(f, line); line := Trim(line);
    if (line = '') or (line[1] = '#') or (line[1] = ';') then Continue;
    if line[1] = '[' then begin inDef := SameText(line, '[default]'); Continue; end;
    if not inDef then Continue;
    p := Pos('=', line); if p = 0 then Continue;
    k := Trim(Copy(line, 1, p-1));
    if SameText(k, Key) then begin Result := Trim(Copy(line, p+1, MaxInt)); Break; end;
  end;
  Close(f);
end;

var
  h: HMODULE; MkDir_: TMkDir; FindFirst_: TFindFirst; InitW_: TInitW;
  fd: TWin32FindDataW; hf: THandle; le: DWORD;
  cred, ak, sk: string; cli: TS3Client; st: Integer;
begin
  h := LoadLibrary('WvN-S3-fpc-rel.wfx64');
  if h = 0 then begin writeln('LoadLibrary failed: ', GetLastError); Halt(2); end;
  InitW_     := TInitW(GetProcAddress(h, 'FsInitW'));
  MkDir_     := TMkDir(GetProcAddress(h, 'FsMkDirW'));
  FindFirst_ := TFindFirst(GetProcAddress(h, 'FsFindFirstW'));
  InitW_(0, nil, nil, nil);

  writeln('mkdir \hydra-build\_wfxtest\emptydir -> ', MkDir_(PWideChar(WideString('\hydra-build\_wfxtest\emptydir'))));

  SetLastError(0);
  hf := FindFirst_(PWideChar(WideString('\hydra-build\_wfxtest\emptydir\')), fd);
  le := GetLastError;
  writeln('FindFirst(...\emptydir\)  handle=', hf,
    '  invalid=', hf = THandle(INVALID_HANDLE_VALUE),
    '  GetLastError=', le, '  (ERROR_NO_MORE_FILES=', ERROR_NO_MORE_FILES, ')');

  SetLastError(0);
  hf := FindFirst_(PWideChar(WideString('\hydra-build\_wfxtest\emptydir')), fd);
  le := GetLastError;
  writeln('FindFirst(...\emptydir)   handle=', hf,
    '  invalid=', hf = THandle(INVALID_HANDLE_VALUE),
    '  GetLastError=', le);

  FreeLibrary(h);

  // cleanup the marker
  cred := GetEnvironmentVariable('USERPROFILE') + '\.aws\credentials';
  ak := ReadIni(cred, 'aws_access_key_id'); sk := ReadIni(cred, 'aws_secret_access_key');
  cli := TS3Client.Create(ak, sk, 'us-east-1');
  try cli.DeleteObject('hydra-build', '_wfxtest/emptydir/', st);
      writeln('cleanup delete status=', st);
  finally cli.Free; end;
end.
