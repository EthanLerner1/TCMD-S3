program branchtest;
{$mode objfpc}{$H+}
// Mimics Total Commander Branch View (Ctrl+B): holds a parent FsFindFirstW handle
// OPEN while it opens+drains a child FsFindFirstW, then resumes the parent. A
// reentrant plugin must give the parent back the same entries as a clean
// single-shot enumeration. A non-reentrant one (single gList/gIndex) corrupts it.
uses windows, SysUtils, Classes, fpcs3;

type
  TMkDir     = function(Path: PWideChar): BOOL; stdcall;
  TFindFirst = function(Path: PWideChar; var fd: TWin32FindDataW): THandle; stdcall;
  TFindNext  = function(Hdl: THandle; var fd: TWin32FindDataW): LongBool; stdcall;
  TFindClose = function(Hdl: THandle): Integer; stdcall;
  TInitW     = function(nr: Integer; a,b,c: Pointer): Integer; stdcall;

var
  h: HMODULE;
  MkDir_: TMkDir; FindFirst_: TFindFirst; FindNext_: TFindNext;
  FindClose_: TFindClose; InitW_: TInitW;

function NameOf(const fd: TWin32FindDataW): string;
begin
  Result := WideString(PWideChar(@fd.cFileName[0]));
end;

// Minimal [default]-section INI reader, same shape as emptydirtest.pas.
function ReadIniCred(const Key: string): string;
var f: Text; line, k, path: string; p: Integer; inDef: Boolean;
begin
  Result := ''; inDef := False;
  path := GetEnvironmentVariable('USERPROFILE') + '\.aws\credentials';
  if not FileExists(path) then Exit;
  Assign(f, path); Reset(f);
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

function IsDir(const fd: TWin32FindDataW): Boolean;
begin
  Result := (fd.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0;
end;

// Clean single-shot enumeration: open, drain, close. No interleaving.
procedure Enumerate(const path: string; out names: TStringList);
var fd: TWin32FindDataW; hf: THandle; more: Boolean;
begin
  names := TStringList.Create;
  hf := FindFirst_(PWideChar(WideString(path)), fd);
  if hf = THandle(INVALID_HANDLE_VALUE) then Exit;
  more := True;
  while more do
  begin
    names.Add((BoolToStr(IsDir(fd), 'D', 'F')) + ' ' + NameOf(fd));
    more := FindNext_(hf, fd);
  end;
  FindClose_(hf);
end;

procedure Dump(const title: string; l: TStringList);
var i: Integer;
begin
  writeln('  ', title, ' (', l.Count, ')');
  for i := 0 to l.Count-1 do writeln('    ', l[i]);
end;

var
  parentBucket, childName: string;
  parentInterleaved, parentClean, childList: TStringList;
  fdP, fdC: TWin32FindDataW; hP, hC: THandle; more: Boolean;
  i: Integer; mismatch: Boolean;
  hf: THandle; le: DWORD; fd: TWin32FindDataW;
  cli: TS3Client; st: Integer;
begin
  h := LoadLibrary('WvN-S3-fpc-rel.wfx64');
  if h = 0 then begin writeln('LoadLibrary failed: ', GetLastError); Halt(2); end;
  InitW_     := TInitW(GetProcAddress(h, 'FsInitW'));
  MkDir_     := TMkDir(GetProcAddress(h, 'FsMkDirW'));
  FindFirst_ := TFindFirst(GetProcAddress(h, 'FsFindFirstW'));
  FindNext_  := TFindNext(GetProcAddress(h, 'FsFindNextW'));
  FindClose_ := TFindClose(GetProcAddress(h, 'FsFindClose'));
  InitW_(0, nil, nil, nil);

  parentBucket := '\hydra-build\';

  // ===== Step 1: open parent, read until first [dir] subfolder =====
  parentInterleaved := TStringList.Create;
  childName := '';
  hP := FindFirst_(PWideChar(WideString(parentBucket)), fdP);
  if hP = THandle(INVALID_HANDLE_VALUE) then
    begin writeln('parent enumeration empty - cannot test'); Halt(3); end;
  more := True;
  while more do
  begin
    parentInterleaved.Add((BoolToStr(IsDir(fdP), 'D', 'F')) + ' ' + NameOf(fdP));
    if (childName = '') and IsDir(fdP) then childName := NameOf(fdP);
    if childName <> '' then Break;   // stop right after first subdir seen
    more := FindNext_(hP, fdP);
  end;
  if childName = '' then begin writeln('no subdir in parent - cannot test'); Halt(3); end;
  writeln('parent="', parentBucket, '"  first subdir="', childName, '"');

  // ===== Step 2: WITHOUT closing hP, fully enumerate the child =====
  childList := TStringList.Create;
  hC := FindFirst_(PWideChar(WideString(parentBucket + childName + '\')), fdC);
  if hC <> THandle(INVALID_HANDLE_VALUE) then
  begin
    more := True;
    while more do
    begin
      childList.Add((BoolToStr(IsDir(fdC), 'D', 'F')) + ' ' + NameOf(fdC));
      more := FindNext_(hC, fdC);
    end;
    FindClose_(hC);
  end;

  // ===== Step 3: resume the parent to the end =====
  while FindNext_(hP, fdP) do
    parentInterleaved.Add((BoolToStr(IsDir(fdP), 'D', 'F')) + ' ' + NameOf(fdP));
  FindClose_(hP);

  // ===== Step 4: clean single-shot parent, compare =====
  Enumerate(parentBucket, parentClean);

  Dump('child (drained while parent open)', childList);
  Dump('parent INTERLEAVED (steps 1+3)', parentInterleaved);
  Dump('parent CLEAN single-shot', parentClean);

  mismatch := parentInterleaved.Count <> parentClean.Count;
  if not mismatch then
    for i := 0 to parentClean.Count-1 do
      if parentInterleaved[i] <> parentClean[i] then mismatch := True;

  if mismatch then writeln('VERDICT: MISMATCH  (Branch View is broken)')
  else writeln('VERDICT: BRANCH OK  (interleaved == clean)');

  // ===== Extra check (a): a normal non-empty listing is correct =====
  writeln;
  writeln('--- check (a): non-empty listing sanity ---');
  if parentClean.Count > 0 then writeln('  \hydra-build\ has ', parentClean.Count, ' entries -> OK')
  else writeln('  \hydra-build\ empty -> UNEXPECTED FAIL');

  // ===== Extra check (b): empty-directory case + ERROR_NO_MORE_FILES =====
  writeln;
  writeln('--- check (b): empty-directory case ---');
  writeln('  mkdir \hydra-build\_wfxtest\bvempty -> ',
    MkDir_(PWideChar(WideString('\hydra-build\_wfxtest\bvempty'))));
  SetLastError(0);
  hf := FindFirst_(PWideChar(WideString('\hydra-build\_wfxtest\bvempty\')), fd);
  le := GetLastError;
  writeln('  FindFirst(empty) handle-invalid=', hf = THandle(INVALID_HANDLE_VALUE),
    '  GetLastError=', le, '  (want ', ERROR_NO_MORE_FILES, ')');
  if (hf = THandle(INVALID_HANDLE_VALUE)) and (le = ERROR_NO_MORE_FILES) then
    writeln('  EMPTYDIR OK') else writeln('  EMPTYDIR FAIL');

  FreeLibrary(h);

  // cleanup the marker, leave nothing behind
  cli := TS3Client.Create(
    ReadIniCred('aws_access_key_id'), ReadIniCred('aws_secret_access_key'), 'us-east-1');
  try cli.DeleteObject('hydra-build', '_wfxtest/bvempty/', st);
      writeln('  cleanup delete status=', st);
  finally cli.Free; end;
end.
