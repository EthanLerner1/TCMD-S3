program s3list;
{$mode objfpc}{$H+}
uses SysUtils, Classes, StrUtils, fpcs3;

// Read a key from the [default] section of an AWS ini-style file.
function ReadIni(const Path, Section, Key: string): string;
var lines: TStringList; i: Integer; cur, line, k, v: string; p: Integer;
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
      begin
        cur := Copy(line, 2, Length(line)-2);
        Continue;
      end;
      if not SameText(cur, Section) then Continue;
      p := Pos('=', line);
      if p = 0 then Continue;
      k := Trim(Copy(line, 1, p-1));
      v := Trim(Copy(line, p+1, MaxInt));
      if SameText(k, Key) then Exit(v);
    end;
  finally
    lines.Free;
  end;
end;

procedure ExtractTags(const xml, tag: string; out list: TStringList);
var op, cl: string; i, j: Integer;
begin
  list := TStringList.Create;
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

var
  home, cfg, cred, access, secret, region, body, testBucket: string;
  status: Integer;
  cli: TS3Client;
  names, keys, prefixes: TStringList;
  i: Integer;
begin
  home := GetEnvironmentVariable('USERPROFILE');
  cfg  := home + '\.aws\config';
  cred := home + '\.aws\credentials';

  // credentials file wins, else config (matches the fixed plugin behaviour)
  access := ReadIni(cred, 'default', 'aws_access_key_id');
  secret := ReadIni(cred, 'default', 'aws_secret_access_key');
  if access = '' then access := ReadIni(cfg, 'default', 'aws_access_key_id');
  if secret = '' then secret := ReadIni(cfg, 'default', 'aws_secret_access_key');
  region := ReadIni(cred, 'default', 'region');
  if region = '' then region := ReadIni(cfg, 'default', 'region');
  if region = '' then region := 'eu-north-1';

  writeln('access key: ', Copy(access,1,4), '... (', Length(access), ' chars)');
  writeln('region    : ', region);
  writeln;

  if access = '' then begin writeln('NO CREDENTIALS FOUND'); Halt(2); end;

  cli := TS3Client.Create(access, secret, region);
  try
    writeln('=== ListBuckets ===');
    cli.ListBucketsXML(body, status);
    writeln('HTTP ', status);
    if status <> 200 then begin writeln(body); Halt(1); end;
    ExtractTags(body, 'Name', names);
    for i := 0 to names.Count-1 do writeln('  bucket: ', names[i]);

    if names.Count = 0 then Halt(1);
    testBucket := names[0];

    // Deliberately break the region to prove auto-correction via x-amz-bucket-region.
    cli.Region := 'eu-west-1';
    writeln;
    writeln('=== ListObjects (', testBucket, ', root)  [starting region deliberately WRONG: eu-west-1] ===');
    cli.ListObjectsXML(testBucket, '', body, status);
    writeln('HTTP ', status, '   region after auto-detect: ', cli.Region);
    if status <> 200 then begin writeln(Copy(body,1,600)); Halt(1); end;
    ExtractTags(body, 'Prefix', prefixes);
    ExtractTags(body, 'Key', keys);
    for i := 0 to prefixes.Count-1 do
      if prefixes[i] <> '' then writeln('  [dir]  ', prefixes[i]);
    for i := 0 to keys.Count-1 do writeln('  [file] ', keys[i]);

    // Download a known small object (also exercises a key whose first folder
    // equals the bucket name -- the original navigation collision case).
    writeln;
    writeln('=== GetObject download ===');
    cli.Region := 'eu-north-1';
    cli.GetObjectToFile('hydra-build',
      'hydra-build/linux-build/models/RTX40/features/voice/wav2vec2/config.json',
      GetTempDir + 's3dl.bin', status);
    with TFileStream.Create(GetTempDir + 's3dl.bin', fmOpenRead) do
    try
      writeln('HTTP ', status, '   saved ', Size, ' bytes (expected 1568)');
      if (status = 200) and (Size = 1568) then writeln('  DOWNLOAD OK')
      else writeln('  DOWNLOAD MISMATCH');
    finally Free; end;
  finally
    cli.Free;
  end;
  writeln;
  writeln('DONE');
end.
