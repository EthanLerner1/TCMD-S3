program mkdirtest;
{$mode objfpc}{$H+}
// Live driver: LoadLibrary the test .wfx64, call FsMkDirW against real AWS,
// verify the marker via FsFindFirstW, then clean up with fpcs3.DeleteObject.
uses windows, SysUtils, Classes, fpcs3;

const
  DLL = 'WvN-S3-fpc-test.wfx64';
  BUCKET = 'hydra-build';

type
  TFsMkDirW    = function(Path: PWideChar): BOOL; stdcall;
  TFsFindFirstW= function(Path: PWideChar; var FindData: TWin32FindDataW): THandle; stdcall;
  TFsFindNextW = function(Hdl: THandle; var FindData: TWin32FindDataW): LongBool; stdcall;
  TFsFindClose = function(Hdl: THandle): Integer; stdcall;

function ReadIni(const Path, Section, Key: string): string;
var lines: TStringList; i, p: Integer; cur, line, k: string;
begin
  Result := '';
  if not FileExists(Path) then Exit;
  lines := TStringList.Create;
  try
    lines.LoadFromFile(Path); cur := '';
    for i := 0 to lines.Count-1 do
    begin
      line := Trim(lines[i]);
      if (line = '') or (line[1] = '#') or (line[1] = ';') then Continue;
      if (line[1] = '[') and (line[Length(line)] = ']') then
        begin cur := Copy(line, 2, Length(line)-2); Continue; end;
      if not SameText(cur, Section) then Continue;
      p := Pos('=', line); if p = 0 then Continue;
      k := Trim(Copy(line, 1, p-1));
      if SameText(k, Key) then Exit(Trim(Copy(line, p+1, MaxInt)));
    end;
  finally lines.Free; end;
end;

var
  h: THandle;
  MkDir: TFsMkDirW; FindFirst: TFsFindFirstW; FindNext: TFsFindNextW; FindClose: TFsFindClose;
  fd: TWin32FindDataW; fh: THandle;
  found: Boolean; name: WideString;
  s3: TS3Client; cred, access, secret: string; status: Integer;
begin
  h := LoadLibrary(DLL);
  if h = 0 then begin writeln('LoadLibrary failed'); Halt(1); end;
  MkDir     := TFsMkDirW(GetProcAddress(h, 'FsMkDirW'));
  FindFirst := TFsFindFirstW(GetProcAddress(h, 'FsFindFirstW'));
  FindNext  := TFsFindNextW(GetProcAddress(h, 'FsFindNextW'));
  FindClose := TFsFindClose(GetProcAddress(h, 'FsFindClose'));
  if (MkDir = nil) or (FindFirst = nil) then begin writeln('GetProcAddress failed'); Halt(1); end;

  // 1) mkdir
  writeln('FsMkDirW(\', BUCKET, '\_wfxtest\newfolder) ...');
  if MkDir('\' + BUCKET + '\_wfxtest\newfolder') then
    writeln('  -> True (mkdir OK)')
  else
    begin writeln('  -> False (mkdir FAILED)'); Halt(1); end;

  // 2) verify: list \bucket\_wfxtest\ and look for [dir] newfolder
  writeln('FsFindFirstW(\', BUCKET, '\_wfxtest\) ...');
  found := False;
  fh := FindFirst(PWideChar(WideString('\' + BUCKET + '\_wfxtest\')), fd);
  if fh <> THandle(INVALID_HANDLE_VALUE) then
  begin
    repeat
      name := WideString(PWideChar(@fd.cFileName[0]));
      if (fd.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
        writeln('  [dir]  ', name)
      else
        writeln('  [file] ', name);
      if name = 'newfolder' then found := True;
    until not FindNext(fh, fd);
    FindClose(fh);
  end;
  if found then writeln('  -> newfolder present as [dir] (VERIFIED)')
  else begin writeln('  -> newfolder NOT found (FAIL)'); Halt(1); end;

  // 3) cleanup via fpcs3 client (delete both markers)
  cred := GetEnvironmentVariable('USERPROFILE') + '\.aws\credentials';
  access := ReadIni(cred, 'default', 'aws_access_key_id');
  secret := ReadIni(cred, 'default', 'aws_secret_access_key');
  s3 := TS3Client.Create(access, secret, 'us-east-1');  // auto-corrects region
  try
    if s3.DeleteObject(BUCKET, '_wfxtest/newfolder/', status) then
      writeln('cleanup: deleted _wfxtest/newfolder/ (status ', status, ')')
    else
      writeln('cleanup: FAILED to delete _wfxtest/newfolder/ (status ', status, ')');
    if s3.DeleteObject(BUCKET, '_wfxtest/', status) then
      writeln('cleanup: deleted _wfxtest/ (status ', status, ')')
    else
      writeln('cleanup: _wfxtest/ delete status ', status, ' (may not have existed)');
  finally s3.Free; end;

  FreeLibrary(h);
  writeln('DONE.');
end.
