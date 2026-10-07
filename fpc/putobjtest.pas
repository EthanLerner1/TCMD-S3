program putobjtest;
{$mode objfpc}{$H+}
// Live round-trip test for the upload feature.
// - uploads a temp file via the DLL's FsPutFileW (as TC would)
// - verifies it landed by downloading it back (fpcs3.GetObjectToFile) & comparing bytes
// - cleans up with fpcs3.DeleteObject so nothing is left in the bucket
// - exercises the abort path (progress returns 1 -> FS_FILE_USERABORT)
uses windows, SysUtils, Classes, fpcs3;

const
  BUCKET = 'hydra-build';
  KEY    = '_wfxtest/upload-probe.bin';
  REMOTE = '\hydra-build\_wfxtest\upload-probe.bin';

type
  TPutFile = function(Local, Remote: PWideChar; Flags: Integer): Integer; stdcall;
  TInitW   = function(nr: Integer; a,b,c: Pointer): Integer; stdcall;
  TProgressProcW = function(PluginNr: Integer; Source, Target: PWideChar;
    PercentDone: Integer): Integer; stdcall;

var
  gAbort: Boolean = False;
  gCalls: Integer = 0;

function MyProgress(PluginNr: Integer; Source, Target: PWideChar;
  Percent: Integer): Integer; stdcall;
begin
  Inc(gCalls);
  writeln('    progress: ', Percent, '%');
  if gAbort then Result := 1 else Result := 0;
end;

// --- credentials, same logic as the plugin's EnsureClient ------------------
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

function MakeClient: TS3Client;
var home, cred, access, secret: string;
begin
  home := GetEnvironmentVariable('USERPROFILE');
  cred := home + '\.aws\credentials';
  access := ReadIni(cred, 'default', 'aws_access_key_id');
  secret := ReadIni(cred, 'default', 'aws_secret_access_key');
  Result := TS3Client.Create(access, secret, 'us-east-1'); // auto-corrects
end;

function FileBytes(const fn: string): TBytes;
var fs: TFileStream;
begin
  fs := TFileStream.Create(fn, fmOpenRead);
  try SetLength(Result, fs.Size); if fs.Size > 0 then fs.ReadBuffer(Result[0], fs.Size);
  finally fs.Free; end;
end;

var
  h: HMODULE; InitW_: TInitW; PutFile_: TPutFile;
  cli: TS3Client; local, dl: string; fs: TFileStream;
  i, r, status: Integer; ok: Boolean;
  orig, back: TBytes;
begin
  h := LoadLibrary('WvN-S3-fpc-test.wfx64');
  if h = 0 then begin writeln('LoadLibrary failed: ', GetLastError); Halt(2); end;
  InitW_   := TInitW(GetProcAddress(h, 'FsInitW'));
  PutFile_ := TPutFile(GetProcAddress(h, 'FsPutFileW'));
  if PutFile_ = nil then begin writeln('FsPutFileW not exported'); Halt(3); end;
  InitW_(0, @MyProgress, nil, nil);

  // 1. make a temp file. 2 MB so the 1-MB-cadence progress callback actually
  //    fires (needed to exercise the abort path too).
  local := GetTempDir + 'wfx-upload-probe.bin';
  fs := TFileStream.Create(local, fmCreate);
  try for i := 0 to (2*1024*1024)-1 do fs.WriteByte((i * 37 + 11) and $FF);
  finally fs.Free; end;
  orig := FileBytes(local);
  writeln('made local probe: ', local, '  bytes=', Length(orig));

  // 2. upload via the DLL export (as TC would)
  writeln('--- FsPutFileW upload ---');
  gAbort := False; gCalls := 0;
  r := PutFile_(PWideChar(WideString(local)), PWideChar(WideString(REMOTE)), 0);
  writeln('  result=', r, '  (expected 0=FS_FILE_OK)  progress-calls=', gCalls);

  // 3. verify: download it back and compare bytes
  cli := MakeClient;
  try
    dl := GetTempDir + 'wfx-upload-probe.dl';
    ok := cli.GetObjectToFile(BUCKET, KEY, dl, status) and (status = 200);
    writeln('--- verify round-trip ---');
    if ok then
    begin
      back := FileBytes(dl);
      writeln('  downloaded bytes=', Length(back), '  http=', status);
      if (Length(back) = Length(orig)) and CompareMem(@back[0], @orig[0], Length(orig)) then
        writeln('  BYTES MATCH - UPLOAD OK')
      else
        writeln('  BYTE MISMATCH - FAIL');
    end
    else
      writeln('  download for verify failed, http=', status, ' - FAIL');
    SysUtils.DeleteFile(dl);

    // 4. cleanup: delete the probe object
    writeln('--- cleanup (DeleteObject) ---');
    ok := cli.DeleteObject(BUCKET, KEY, status);
    writeln('  delete http=', status, '  ok=', ok);
    if ok then writeln('  CLEANUP OK') else writeln('  CLEANUP FAIL');

    // 5. abort path: upload again but abort via progress callback
    writeln('--- FsPutFileW abort test ---');
    gAbort := True; gCalls := 0;
    r := PutFile_(PWideChar(WideString(local)), PWideChar(WideString(REMOTE)), 0);
    writeln('  result=', r, '  (expected 5=USERABORT)  progress-calls=', gCalls);
    // whether or not a partial object landed, clean up defensively
    cli.DeleteObject(BUCKET, KEY, status);
    writeln('  post-abort cleanup http=', status);
  finally cli.Free; end;

  SysUtils.DeleteFile(local);
  FreeLibrary(h);
end.
