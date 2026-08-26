program deltest;
{$mode objfpc}{$H+}
// Live test for file + folder deletion via the WFX exports, against real S3.
uses windows, SysUtils, Classes, fpcs3;

type
  TMkDir      = function(Path: PWideChar): BOOL; stdcall;
  TPutFile    = function(Local, Remote: PWideChar; Flags: Integer): Integer; stdcall;
  TDeleteFile = function(Remote: PWideChar): BOOL; stdcall;
  TRemoveDir  = function(Remote: PWideChar): BOOL; stdcall;
  TFindFirst  = function(Path: PWideChar; var fd: TWin32FindDataW): THandle; stdcall;
  TFindNext   = function(Hdl: THandle; var fd: TWin32FindDataW): LongBool; stdcall;
  TFindClose  = function(Hdl: THandle): Integer; stdcall;
  TInitW      = function(nr: Integer; a,b,c: Pointer): Integer; stdcall;

var
  h: HMODULE;
  MkDir_: TMkDir; PutFile_: TPutFile; DeleteFile_: TDeleteFile; RemoveDir_: TRemoveDir;
  FindFirst_: TFindFirst; FindNext_: TFindNext; FindClose_: TFindClose; InitW_: TInitW;

// True if `name` appears in the listing of `dir`.
function Listed(const dir, name: string): Boolean;
var fd: TWin32FindDataW; hf: THandle; more: Boolean;
begin
  Result := False;
  hf := FindFirst_(PWideChar(WideString(dir)), fd);
  if hf = THandle(INVALID_HANDLE_VALUE) then Exit;
  more := True;
  while more do
  begin
    if WideString(PWideChar(@fd.cFileName[0])) = name then Result := True;
    more := FindNext_(hf, fd);
  end;
  FindClose_(hf);
end;

var
  local: string; f: TFileStream; b: array[0..1023] of Byte; i, r: Integer;
  okFile, okDir: Boolean;
begin
  h := LoadLibrary('WvN-S3-fpc-rel.wfx64');
  if h = 0 then begin writeln('LoadLibrary failed: ', GetLastError); Halt(2); end;
  InitW_      := TInitW(GetProcAddress(h, 'FsInitW'));
  MkDir_      := TMkDir(GetProcAddress(h, 'FsMkDirW'));
  PutFile_    := TPutFile(GetProcAddress(h, 'FsPutFileW'));
  DeleteFile_ := TDeleteFile(GetProcAddress(h, 'FsDeleteFileW'));
  RemoveDir_  := TRemoveDir(GetProcAddress(h, 'FsRemoveDirW'));
  FindFirst_  := TFindFirst(GetProcAddress(h, 'FsFindFirstW'));
  FindNext_   := TFindNext(GetProcAddress(h, 'FsFindNextW'));
  FindClose_  := TFindClose(GetProcAddress(h, 'FsFindClose'));
  InitW_(0, nil, nil, nil);

  // --- file delete ---
  local := GetTempDir + 'wfx-delprobe.bin';
  f := TFileStream.Create(local, fmCreate);
  try for i := 0 to High(b) do b[i] := i and $FF; f.WriteBuffer(b, SizeOf(b)); finally f.Free; end;
  r := PutFile_(PWideChar(WideString(local)),
                PWideChar(WideString('\hydra-build\_wfxtest\delfile.bin')), 0);
  writeln('upload probe -> result=', r, ' (0=OK)');
  writeln('  listed before delete: ', Listed('\hydra-build\_wfxtest\', 'delfile.bin'));
  writeln('FsDeleteFileW -> ', DeleteFile_(PWideChar(WideString('\hydra-build\_wfxtest\delfile.bin'))));
  okFile := not Listed('\hydra-build\_wfxtest\', 'delfile.bin');
  writeln('  listed after delete:  ', not okFile, '   => ', BoolToStr(okFile, 'FILE DELETE OK', 'FILE DELETE FAIL'));

  // --- folder delete (marker) ---
  writeln('mkdir delfolder -> ', MkDir_(PWideChar(WideString('\hydra-build\_wfxtest\delfolder'))));
  writeln('  listed before rmdir: ', Listed('\hydra-build\_wfxtest\', 'delfolder'));
  writeln('FsRemoveDirW -> ', RemoveDir_(PWideChar(WideString('\hydra-build\_wfxtest\delfolder'))));
  okDir := not Listed('\hydra-build\_wfxtest\', 'delfolder');
  writeln('  listed after rmdir:  ', not okDir, '   => ', BoolToStr(okDir, 'FOLDER DELETE OK', 'FOLDER DELETE FAIL'));

  FreeLibrary(h);
  SysUtils.DeleteFile(local);
  if okFile and okDir then writeln('ALL OK') else begin writeln('FAILED'); Halt(1); end;
end.
