library s3wfx;
{$mode objfpc}{$H+}
// Total Commander WFX plugin for S3, built with Free Pascal (no Embarcadero).
// v1: browse buckets/folders + download. Write ops (put/delete/rename/mkdir) TODO.
uses
  windows, SysUtils, Classes, StrUtils, fpcs3, fpcs3_hash;

type
  TEntry = record
    Name: string;
    IsDir: Boolean;
    Size: Int64;
  end;
  // Total Commander's progress callback: returns 1 if the user wants to abort.
  TProgressProcW = function(PluginNr: Integer; Source, Target: PWideChar;
    PercentDone: Integer): Integer; stdcall;

const
  FS_FILE_OK           = 0;
  FS_FILE_WRITEERROR   = 1;
  FS_FILE_READERROR    = 3;
  FS_FILE_USERABORT    = 5;
  FS_FILE_NOTSUPPORTED = 6;

var
  gS3: TS3Client = nil;
  gList: array of TEntry;
  gIndex: Integer = -1;
  gProgressProc: TProgressProcW = nil;
  gPluginNr: Integer = 0;
  gCurSource, gCurTarget: WideString;

// ---- credentials (credentials file wins, else config) --------------------
function ReadIni(const Path, Section, Key: string): string;
var lines: TStringList; i, p: Integer; cur, line, k: string;
begin
  Result := '';
  if not FileExists(Path) then Exit;
  lines := TStringList.Create;
  try
    lines.LoadFromFile(Path);
    cur := '';
    for i := 0 to lines.Count-1 do
    begin
      line := Trim(lines[i]);
      if (line = '') or (line[1] = '#') or (line[1] = ';') then Continue;
      if (line[1] = '[') and (line[Length(line)] = ']') then
        begin cur := Copy(line, 2, Length(line)-2); Continue; end;
      if not SameText(cur, Section) then Continue;
      p := Pos('=', line);
      if p = 0 then Continue;
      k := Trim(Copy(line, 1, p-1));
      if SameText(k, Key) then Exit(Trim(Copy(line, p+1, MaxInt)));
    end;
  finally
    lines.Free;
  end;
end;

function EnsureClient: Boolean;
var home, cfg, cred, access, secret, region: string;
begin
  if gS3 <> nil then Exit(True);
  home := GetEnvironmentVariable('USERPROFILE');
  cred := home + '\.aws\credentials';
  cfg  := home + '\.aws\config';
  access := ReadIni(cred, 'default', 'aws_access_key_id');
  secret := ReadIni(cred, 'default', 'aws_secret_access_key');
  if access = '' then access := ReadIni(cfg, 'default', 'aws_access_key_id');
  if secret = '' then secret := ReadIni(cfg, 'default', 'aws_secret_access_key');
  region := ReadIni(cred, 'default', 'region');
  if region = '' then region := ReadIni(cfg, 'default', 'region');
  if region = '' then region := 'us-east-1'; // any region; auto-corrects per bucket
  Result := access <> '';
  if Result then gS3 := TS3Client.Create(access, secret, region);
end;

// ---- xml + path helpers --------------------------------------------------
procedure ExtractTags(const xml, tag: string; list: TStringList);
var op, cl: string; i, j: Integer;
begin
  op := '<' + tag + '>'; cl := '</' + tag + '>';
  i := Pos(op, xml);
  while i > 0 do
  begin
    j := PosEx(cl, xml, i + Length(op));
    if j = 0 then Break;
    list.Add(Copy(xml, i + Length(op), j - (i + Length(op))));
    i := PosEx(op, xml, j + Length(cl));
  end;
end;

// TC path (\bucket\folder\) -> bucket + s3 prefix (folder/). Strips the leading
// bucket segment by POSITION, so a folder named like the bucket survives.
procedure SplitPath(tcPath: string; out bucket, prefix: string);
var parts: TStringArray; i: Integer;
begin
  bucket := ''; prefix := '';
  while (tcPath <> '') and (tcPath[1] = '\') do Delete(tcPath, 1, 1);
  while (tcPath <> '') and (tcPath[Length(tcPath)] = '\') do Delete(tcPath, Length(tcPath), 1);
  if tcPath = '' then Exit;
  parts := tcPath.Split(['\']);
  bucket := parts[0];
  for i := 1 to High(parts) do
    prefix := prefix + parts[i] + '/';
end;

function LastSegment(s: string): string;
var p: Integer;
begin
  if (s <> '') and (s[Length(s)] = '/') then Delete(s, Length(s), 1);
  p := LastDelimiter('/', s);
  if p > 0 then Result := Copy(s, p+1, MaxInt) else Result := s;
end;

// ---- build the directory listing for a TC path ---------------------------
procedure BuildListing(const tcPath: string);
var
  bucket, prefix, body: string;
  status, i: Integer;
  names, prefixes, keys, sizes: TStringList;
  e: TEntry;
begin
  SetLength(gList, 0);
  if not EnsureClient then Exit;

  SplitPath(tcPath, bucket, prefix);

  if bucket = '' then
  begin
    // root: list buckets
    if not gS3.ListBucketsXML(body, status) then Exit;
    if status <> 200 then Exit;
    names := TStringList.Create;
    try
      ExtractTags(body, 'Name', names);
      for i := 0 to names.Count-1 do
      begin
        e.Name := names[i]; e.IsDir := True; e.Size := 0;
        SetLength(gList, Length(gList)+1); gList[High(gList)] := e;
      end;
    finally names.Free; end;
    Exit;
  end;

  // inside a bucket: list objects at this prefix
  if not gS3.ListObjectsXML(bucket, prefix, body, status) then Exit;
  if status <> 200 then Exit;

  prefixes := TStringList.Create;
  keys := TStringList.Create;
  sizes := TStringList.Create;
  try
    ExtractTags(body, 'Prefix', prefixes);
    ExtractTags(body, 'Key', keys);
    ExtractTags(body, 'Size', sizes);
    // sub-folders (CommonPrefixes)
    for i := 0 to prefixes.Count-1 do
    begin
      if prefixes[i] = '' then Continue;
      if prefixes[i] = prefix then Continue;      // the request prefix echoes back
      e.Name := LastSegment(prefixes[i]); e.IsDir := True; e.Size := 0;
      if e.Name <> '' then
      begin SetLength(gList, Length(gList)+1); gList[High(gList)] := e; end;
    end;
    // files (Contents)
    for i := 0 to keys.Count-1 do
    begin
      if keys[i] = prefix then Continue;          // folder marker itself
      if keys[i].EndsWith('/') then Continue;     // other folder markers
      e.Name := LastSegment(keys[i]);
      e.IsDir := False;
      if i < sizes.Count then e.Size := StrToInt64Def(sizes[i], 0) else e.Size := 0;
      if e.Name <> '' then
      begin SetLength(gList, Length(gList)+1); gList[High(gList)] := e; end;
    end;
  finally
    prefixes.Free; keys.Free; sizes.Free;
  end;
end;

procedure FillFind(var fd: TWin32FindDataW; const e: TEntry);
var w: WideString; n: Integer;
begin
  FillChar(fd, SizeOf(fd), 0);
  if e.IsDir then fd.dwFileAttributes := FILE_ATTRIBUTE_DIRECTORY
  else fd.dwFileAttributes := 0;
  fd.nFileSizeLow  := DWORD(e.Size and $FFFFFFFF);
  fd.nFileSizeHigh := DWORD((e.Size shr 32) and $FFFFFFFF);
  w := UTF8Decode(e.Name);
  n := Length(w); if n > MAX_PATH-1 then n := MAX_PATH-1;
  if n > 0 then Move(w[1], fd.cFileName, n * SizeOf(WideChar));
end;

// Bridges fpcs3's byte-count callback to TC's percent/abort callback.
// Single transfer at a time, so module globals are fine.
function ProgressBridge(BytesDone, BytesTotal: Int64): Boolean;
var pct: Integer;
begin
  if BytesTotal > 0 then pct := Integer((BytesDone * 100) div BytesTotal) else pct := 0;
  if Assigned(gProgressProc) then
    Result := gProgressProc(gPluginNr, PWideChar(gCurSource), PWideChar(gCurTarget), pct) = 1
  else
    Result := False;
end;

// ---- WFX exports ---------------------------------------------------------
function FsInitW(PluginNr: Integer; pProgress, pLog, pRequest: Pointer): Integer; stdcall;
begin
  gPluginNr := PluginNr;
  gProgressProc := TProgressProcW(pProgress);
  Result := 0;
end;

procedure FsGetDefRootName(DefRootName: PAnsiChar; MaxLen: Integer); stdcall;
const nm = 'S3';
begin
  StrLCopy(DefRootName, nm, MaxLen-1);
end;

// The WideString/AnsiString work lives here so the exported FsFindFirstW holds
// no managed locals. On Windows, freeing a WideString temp in the epilogue calls
// SysFreeString (OLE), which resets the OS last-error to 0 — that would wipe the
// SetLastError(ERROR_NO_MORE_FILES) we need for TC to treat an empty S3 "folder"
// as an enterable empty dir rather than a read error.
procedure FindFirstImpl(Path: PWideChar; var FindData: TWin32FindDataW; out isEmpty: Boolean);
begin
  BuildListing(WideString(Path));
  isEmpty := Length(gList) = 0;
  if isEmpty then Exit;
  gIndex := 0;
  FillFind(FindData, gList[0]);
end;

function FsFindFirstW(Path: PWideChar; var FindData: TWin32FindDataW): THandle; stdcall;
var isEmpty: Boolean;
begin
  FindFirstImpl(Path, FindData, isEmpty);
  if isEmpty then
  begin
    SetLastError(ERROR_NO_MORE_FILES);   // must be the last call — no managed temps here
    Result := THandle(INVALID_HANDLE_VALUE);
  end
  else
    Result := THandle(1);
end;

function FsFindNextW(Hdl: THandle; var FindData: TWin32FindDataW): LongBool; stdcall;
begin
  Inc(gIndex);
  if (gIndex < 0) or (gIndex >= Length(gList)) then Exit(False);
  FillFind(FindData, gList[gIndex]);
  Result := True;
end;

function FsFindClose(Hdl: THandle): Integer; stdcall;
begin
  Result := 0;
end;

function FsGetFileW(RemoteName, LocalName: PWideChar; CopyFlags: Integer;
  RemoteInfo: Pointer): Integer; stdcall;
var bucket, prefix, key: string; status: Integer; aborted: Boolean;
begin
  if not EnsureClient then Exit(FS_FILE_READERROR);
  SplitPath(WideString(RemoteName), bucket, prefix);
  if bucket = '' then Exit(FS_FILE_NOTSUPPORTED);
  // prefix already carries a trailing '/'; the key is prefix minus that slash
  key := prefix;
  if (key <> '') and (key[Length(key)] = '/') then Delete(key, Length(key), 1);
  if key = '' then Exit(FS_FILE_NOTSUPPORTED);

  gCurSource := WideString(RemoteName);
  gCurTarget := WideString(LocalName);
  aborted := False;
  if gS3.GetObjectToFile(bucket, key, WideString(LocalName), status,
       @ProgressBridge, @aborted) and (status = 200) then
    Result := FS_FILE_OK
  else if aborted then
    Result := FS_FILE_USERABORT
  else
    Result := FS_FILE_READERROR;
end;

function FsPutFileW(LocalName, RemoteName: PWideChar; CopyFlags: Integer): Integer; stdcall;
var bucket, prefix, key: string; status: Integer; aborted: Boolean;
begin
  if not EnsureClient then Exit(FS_FILE_WRITEERROR);
  SplitPath(WideString(RemoteName), bucket, prefix);
  if bucket = '' then Exit(FS_FILE_NOTSUPPORTED);
  // RemoteName already ends in the filename, so SplitPath's prefix is the full
  // key with a trailing '/'. Strip it — same trick FsGetFileW uses.
  key := prefix;
  if (key <> '') and (key[Length(key)] = '/') then Delete(key, Length(key), 1);
  if key = '' then Exit(FS_FILE_NOTSUPPORTED);
  // ponytail: no overwrite-check on CopyFlags — S3 PUT overwrites by default,
  // which is the correct behaviour for a file copy here anyway.

  gCurSource := WideString(LocalName);
  gCurTarget := WideString(RemoteName);
  aborted := False;
  if gS3.PutObjectFromFile(bucket, key, WideString(LocalName), status,
       @ProgressBridge, @aborted) and (status = 200) then
    Result := FS_FILE_OK
  else if aborted then
    Result := FS_FILE_USERABORT
  else
    Result := FS_FILE_WRITEERROR;
end;

function FsMkDirW(Path: PWideChar): BOOL; stdcall;
var bucket, prefix: string; status: Integer;
begin
  if not EnsureClient then Exit(False);
  SplitPath(WideString(Path), bucket, prefix);
  // ponytail: bucket='' means mkdir at the S3 root, i.e. create a bucket — out
  // of scope. prefix already ends in '/', which is exactly the folder-marker key.
  if (bucket = '') or (prefix = '') then Exit(False);
  Result := gS3.CreateFolder(bucket, prefix, status) and (status = 200);
end;

exports
  FsInitW          name 'FsInitW',
  FsGetDefRootName name 'FsGetDefRootName',
  FsFindFirstW     name 'FsFindFirstW',
  FsFindNextW      name 'FsFindNextW',
  FsFindClose      name 'FsFindClose',
  FsGetFileW       name 'FsGetFileW',
  FsPutFileW       name 'FsPutFileW',
  FsMkDirW         name 'FsMkDirW';

begin
end.
