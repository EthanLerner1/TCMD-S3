program mptest;
{$mode objfpc}{$H+}
// Live test for parallel multipart download: forces the multipart path on an
// 8.7MB object (threshold lowered), proves it's byte-identical to a single
// stream, and checks the abort path. Against real S3 (bucket hydra-build).
uses SysUtils, Classes, fpcs3, fpcs3_hash;

const
  BUCKET = 'hydra-build';
  KEY    = 'hydra-build/linux-build/models/RTX40/features/voice/DeepFilterNet3.pt';
  SIZE   = 8714073;

var gAbortNow: Boolean = False;
function AbortProg(BytesDone, BytesTotal: Int64): Boolean;
begin Result := gAbortNow; end;

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

function FileHash(const p: string): string;
var fsr: TFileStream; b: TBytes;
begin
  fsr := TFileStream.Create(p, fmOpenRead);
  try SetLength(b, fsr.Size); if fsr.Size > 0 then fsr.ReadBuffer(b[0], fsr.Size);
  finally fsr.Free; end;
  Result := ToHex(SHA256(b));
end;

function FileSizeOf(const p: string): Int64;
var fsr: TFileStream;
begin
  if not FileExists(p) then Exit(-1);
  fsr := TFileStream.Create(p, fmOpenRead);
  try Result := fsr.Size; finally fsr.Free; end;
end;

var
  cred, ak, sk, single, multi, hSingle, hMulti: string;
  cli: TS3Client; st: Integer; ok, okAbort: Boolean; tmp: string;
begin
  cred := GetEnvironmentVariable('USERPROFILE') + '\.aws\credentials';
  ak := ReadIni(cred, 'aws_access_key_id'); sk := ReadIni(cred, 'aws_secret_access_key');
  if ak = '' then begin writeln('NO CREDENTIALS'); Halt(2); end;
  tmp := GetTempDir;
  single := tmp + 'mp-single.bin';
  multi  := tmp + 'mp-multi.bin';

  // 1) single-stream reference (threshold huge so multipart never triggers)
  MultipartThreshold := High(Int64);
  cli := TS3Client.Create(ak, sk, 'us-east-1');   // wrong region on purpose
  try
    writeln('--- single-stream reference download ---');
    cli.GetObjectToFile(BUCKET, KEY, single, st, nil, nil, SIZE);
    writeln('  status=', st, '  size=', FileSizeOf(single), ' (want ', SIZE, ')');
  finally cli.Free; end;

  // 2) multipart (threshold 1MB => 8.7MB object splits across 4 workers)
  MultipartThreshold := 1024 * 1024;
  cli := TS3Client.Create(ak, sk, 'us-east-1');
  try
    writeln('--- multipart download (4 parallel range workers) ---');
    cli.GetObjectToFile(BUCKET, KEY, multi, st, nil, nil, SIZE);
    writeln('  status=', st, '  size=', FileSizeOf(multi), ' (want ', SIZE, ')');
  finally cli.Free; end;

  hSingle := FileHash(single);
  hMulti  := FileHash(multi);
  writeln('  single sha256: ', hSingle);
  writeln('  multi  sha256: ', hMulti);
  ok := (FileSizeOf(multi) = SIZE) and (hMulti = hSingle);
  writeln('  => ', BoolToStr(ok, 'MULTIPART BYTE-IDENTICAL OK', 'MULTIPART MISMATCH FAIL'));

  // 3) abort mid-download: expect False + no leftover file
  MultipartThreshold := 1024 * 1024;
  gAbortNow := True;
  cli := TS3Client.Create(ak, sk, 'us-east-1');
  try
    writeln('--- multipart abort ---');
    ok := cli.GetObjectToFile(BUCKET, KEY, multi, st, @AbortProg, nil, SIZE);
    okAbort := (not ok) and (not FileExists(multi));
    writeln('  returned=', ok, '  file-exists=', FileExists(multi),
            '  => ', BoolToStr(okAbort, 'ABORT OK', 'ABORT FAIL'));
  finally cli.Free; end;

  SysUtils.DeleteFile(single); SysUtils.DeleteFile(multi);
  if (hMulti = hSingle) and (FileSizeOf(single) = -1) and okAbort then
    writeln('ALL OK') else writeln('(see verdicts above)');
end.
