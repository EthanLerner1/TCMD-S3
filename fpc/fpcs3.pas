unit fpcs3;
{$mode objfpc}{$H+}
// Minimal AWS S3 client for FPC: SigV4 signing + HTTPS via wininet (no OpenSSL).
// Enough to replace the Data.Cloud.AmazonAPI calls the plugin needs.
interface

uses SysUtils, Classes, fpcs3_hash;

type
  // Called periodically during a transfer with bytes-so-far / total (total may
  // be 0 if unknown). Return True to abort. Plain function so it can bridge to
  // Total Commander's C-style progress callback.
  TS3Progress = function(BytesDone, BytesTotal: Int64): Boolean;

  TS3Client = class
  private
    FAccess, FSecret, FRegion: string;
    // Core signed request. Payload is the request body (empty for GET/DELETE).
    // Response body is STREAMED raw to RespStream (never buffered whole), so a
    // multi-GB download uses constant memory. On a region redirect the actual
    // bucket region is returned in BucketRegion so the caller can retry.
    function SignedRequest(const Method, Host, CanonicalUri, CanonicalQuery: string;
      const Payload: TBytes; RespStream: TStream;
      out StatusCode: Integer; out BucketRegion: string;
      Progress: TS3Progress = nil; AbortedPtr: PBoolean = nil): Boolean;
    // One streaming PUT attempt (UNSIGNED-PAYLOAD); PutObjectFromFile wraps it
    // with the region-detect retry.
    function PutOnce(const Bucket, Key, LocalFile: string;
      out StatusCode: Integer; out BucketRegion: string;
      Progress: TS3Progress = nil; AbortedPtr: PBoolean = nil): Boolean;
  public
    constructor Create(const AAccess, ASecret, ARegion: string);
    property Region: string read FRegion write FRegion;
    function RegionHost: string;
    function ListBucketsXML(out Body: string; out Status: Integer): Boolean;
    // These auto-detect and follow the bucket's real region on a 301/400.
    function ListObjectsXML(const Bucket, Prefix: string;
      out Body: string; out Status: Integer): Boolean;
    function GetObjectToFile(const Bucket, Key, LocalFile: string;
      out Status: Integer; Progress: TS3Progress = nil;
      AbortedPtr: PBoolean = nil): Boolean;
    // Streams the local file to S3 (constant memory) via PUT with
    // x-amz-content-sha256: UNSIGNED-PAYLOAD, so we never hash the whole file.
    function PutObjectFromFile(const Bucket, Key, LocalFile: string;
      out Status: Integer; Progress: TS3Progress = nil;
      AbortedPtr: PBoolean = nil): Boolean;
    // Region-aware DELETE (empty body). Mainly so tests can clean up.
    function DeleteObject(const Bucket, Key: string; out Status: Integer): Boolean;
    // Region-aware PUT of an empty object at Key (Key ends in '/') — the S3
    // folder-marker convention. Success = HTTP 200.
    function CreateFolder(const Bucket, Key: string; out Status: Integer): Boolean;
  end;

function UriEncode(const S: string; EncodeSlash: Boolean): string;

implementation

uses windows, wininet;

const
  EMPTY_SHA256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

function UriEncode(const S: string; EncodeSlash: Boolean): string;
const unreserved = ['A'..'Z','a'..'z','0'..'9','-','_','.','~'];
var i: Integer; c: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if (c in unreserved) or ((c = '/') and (not EncodeSlash)) then
      Result := Result + c
    else
      Result := Result + '%' + IntToHex(Ord(c), 2);
  end;
end;

procedure UtcNowStamp(out AmzDate, DateStamp: string);
var st: TSystemTime;
begin
  GetSystemTime(st{%H-});
  AmzDate := Format('%.4d%.2d%.2dT%.2d%.2d%.2dZ',
    [st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond]);
  DateStamp := Format('%.4d%.2d%.2d', [st.wYear, st.wMonth, st.wDay]);
end;

function QueryHeader(hRequest: HINTERNET; const Name: string): string;
var buf: array[0..255] of Char; len, idx: DWORD;
begin
  Result := '';
  StrPCopy(buf, Name);
  len := SizeOf(buf); idx := 0;
  if HttpQueryInfo(hRequest, HTTP_QUERY_CUSTOM, @buf[0], len, idx) then
    Result := Copy(buf, 1, len div SizeOf(Char));
end;

// Read a standard response header (by HTTP_QUERY_* flag) as a string.
function QueryInfoStr(hRequest: HINTERNET; flag: DWORD): string;
var buf: array[0..127] of Char; len, idx: DWORD;
begin
  Result := '';
  len := SizeOf(buf); idx := 0;
  if HttpQueryInfo(hRequest, flag, @buf[0], len, idx) then
    Result := Copy(buf, 1, len div SizeOf(Char));
end;

constructor TS3Client.Create(const AAccess, ASecret, ARegion: string);
begin
  FAccess := AAccess; FSecret := ASecret; FRegion := ARegion;
end;

function TS3Client.RegionHost: string;
begin
  Result := 's3.' + FRegion + '.amazonaws.com';
end;

function TS3Client.SignedRequest(const Method, Host, CanonicalUri, CanonicalQuery: string;
  const Payload: TBytes; RespStream: TStream;
  out StatusCode: Integer; out BucketRegion: string;
  Progress: TS3Progress; AbortedPtr: PBoolean): Boolean;
var
  amzDate, dateStamp, scope, canonicalHeaders, signedHeaders: string;
  canonicalRequest, stringToSign, authHeader, headers, payloadHash: string;
  kDate, kRegion, kService, kSigning, sig: TBytes;
  hSession, hConnect, hRequest: HINTERNET;
  flags: DWORD;
  buf: array[0..65535] of Byte;
  bytesRead: DWORD;
  statusBuf, statusLen, idx: DWORD;
  optPtr: Pointer; optLen: DWORD;
  total, done, lastReport: Int64;
begin
  Result := False; StatusCode := 0; BucketRegion := '';
  if AbortedPtr <> nil then AbortedPtr^ := False;
  UtcNowStamp(amzDate, dateStamp);

  if Length(Payload) = 0 then
    payloadHash := EMPTY_SHA256
  else
    payloadHash := ToHex(SHA256(Payload));

  signedHeaders := 'host;x-amz-content-sha256;x-amz-date';
  canonicalHeaders :=
    'host:' + Host + #10 +
    'x-amz-content-sha256:' + payloadHash + #10 +
    'x-amz-date:' + amzDate + #10;

  canonicalRequest :=
    Method + #10 + CanonicalUri + #10 + CanonicalQuery + #10 +
    canonicalHeaders + #10 + signedHeaders + #10 + payloadHash;

  scope := dateStamp + '/' + FRegion + '/s3/aws4_request';
  stringToSign :=
    'AWS4-HMAC-SHA256' + #10 + amzDate + #10 + scope + #10 +
    ToHex(SHA256Str(canonicalRequest));

  kDate    := HMACSHA256(StrToBytes('AWS4' + FSecret), StrToBytes(dateStamp));
  kRegion  := HMACSHA256(kDate, StrToBytes(FRegion));
  kService := HMACSHA256(kRegion, StrToBytes('s3'));
  kSigning := HMACSHA256(kService, StrToBytes('aws4_request'));
  sig      := HMACSHA256(kSigning, StrToBytes(stringToSign));

  authHeader :=
    'AWS4-HMAC-SHA256 Credential=' + FAccess + '/' + scope +
    ', SignedHeaders=' + signedHeaders + ', Signature=' + ToHex(sig);

  headers :=
    'x-amz-date: ' + amzDate + #13#10 +
    'x-amz-content-sha256: ' + payloadHash + #13#10 +
    'Authorization: ' + authHeader + #13#10;

  hSession := InternetOpen('fpcs3/1.0', INTERNET_OPEN_TYPE_PRECONFIG, nil, nil, 0);
  if hSession = nil then Exit;
  try
    hConnect := InternetConnect(hSession, PChar(Host), INTERNET_DEFAULT_HTTPS_PORT,
      nil, nil, INTERNET_SERVICE_HTTP, 0, 0);
    if hConnect = nil then Exit;
    try
      // NO_AUTO_REDIRECT: S3 answers a wrong-region request with 301 +
      // x-amz-bucket-region; we must read that header, not silently follow it.
      flags := INTERNET_FLAG_SECURE or INTERNET_FLAG_RELOAD or
               INTERNET_FLAG_NO_CACHE_WRITE or INTERNET_FLAG_NO_AUTO_REDIRECT;
      hRequest := HttpOpenRequest(hConnect, PChar(Method),
        PChar(CanonicalUri + '?' + CanonicalQuery), nil, nil, nil, flags, 0);
      if hRequest = nil then Exit;
      try
        if Length(Payload) > 0 then
        begin optPtr := @Payload[0]; optLen := Length(Payload); end
        else
        begin optPtr := nil; optLen := 0; end;

        if not HttpSendRequest(hRequest, PChar(headers), Length(headers), optPtr, optLen) then Exit;

        statusBuf := 0; statusLen := SizeOf(statusBuf); idx := 0;
        if HttpQueryInfo(hRequest, HTTP_QUERY_STATUS_CODE or HTTP_QUERY_FLAG_NUMBER,
             @statusBuf, statusLen, idx) then
          StatusCode := statusBuf;

        BucketRegion := QueryHeader(hRequest, 'x-amz-bucket-region');
        total := StrToInt64Def(Trim(QueryInfoStr(hRequest, HTTP_QUERY_CONTENT_LENGTH)), 0);

        // Stream body straight to RespStream; never buffer the whole object.
        done := 0; lastReport := 0;
        while InternetReadFile(hRequest, @buf[0], SizeOf(buf), bytesRead) and (bytesRead > 0) do
        begin
          RespStream.WriteBuffer(buf[0], bytesRead);
          Inc(done, bytesRead);
          // report roughly every 1 MB so a huge file doesn't flood the callback
          if Assigned(Progress) and (done - lastReport >= 1024*1024) then
          begin
            lastReport := done;
            if Progress(done, total) then
            begin
              if AbortedPtr <> nil then AbortedPtr^ := True;
              Break;
            end;
          end;
        end;
        Result := True;
      finally
        InternetCloseHandle(hRequest);
      end;
    finally
      InternetCloseHandle(hConnect);
    end;
  finally
    InternetCloseHandle(hSession);
  end;
end;

function StreamToString(S: TStream): string;
begin
  SetLength(Result, S.Size);
  S.Position := 0;
  if S.Size > 0 then S.ReadBuffer(Result[1], S.Size);
end;

function TS3Client.ListBucketsXML(out Body: string; out Status: Integer): Boolean;
var ms: TMemoryStream; br: string;
begin
  ms := TMemoryStream.Create;
  try
    Result := SignedRequest('GET', RegionHost, '/', '', nil, ms, Status, br);
    Body := StreamToString(ms);
  finally ms.Free; end;
end;

function TS3Client.ListObjectsXML(const Bucket, Prefix: string;
  out Body: string; out Status: Integer): Boolean;
var ms: TMemoryStream; br, query: string; attempt: Integer;
begin
  query := 'delimiter=' + UriEncode('/', True) + '&list-type=2';
  if Prefix <> '' then query := query + '&prefix=' + UriEncode(Prefix, True);
  for attempt := 0 to 1 do
  begin
    ms := TMemoryStream.Create;
    try
      Result := SignedRequest('GET', RegionHost, '/' + Bucket, query, nil, ms, Status, br);
      Body := StreamToString(ms);
    finally ms.Free; end;
    if ((Status = 301) or (Status = 400)) and (br <> '') and (br <> FRegion) then
      FRegion := br            // learned the real region — retry once
    else
      Break;
  end;
end;

function TS3Client.GetObjectToFile(const Bucket, Key, LocalFile: string;
  out Status: Integer; Progress: TS3Progress; AbortedPtr: PBoolean): Boolean;
var fs: TFileStream; br, uri: string; attempt: Integer; aborted: Boolean;
begin
  Result := False;
  if AbortedPtr <> nil then AbortedPtr^ := False;
  uri := '/' + Bucket + '/' + UriEncode(Key, False);
  for attempt := 0 to 1 do
  begin
    aborted := False;
    // Stream directly to disk: on a wrong-region first attempt this writes the
    // small 301 error XML, which the retry truncates away (fmCreate). Constant
    // memory regardless of object size.
    fs := TFileStream.Create(LocalFile, fmCreate);
    try
      SignedRequest('GET', RegionHost, uri, '', nil, fs, Status, br, Progress, @aborted);
    finally fs.Free; end;

    if aborted then
    begin
      if AbortedPtr <> nil then AbortedPtr^ := True;
      SysUtils.DeleteFile(LocalFile);
      Exit(False);
    end;
    if ((Status = 301) or (Status = 400)) and (br <> '') and (br <> FRegion) then
    begin
      FRegion := br;
      Continue;                 // learned real region — retry once
    end;
    Break;
  end;

  if Status = 200 then
    Result := True
  else
    SysUtils.DeleteFile(LocalFile);  // don't leave an error body masquerading as the file
end;

const
  UNSIGNED_PAYLOAD = 'UNSIGNED-PAYLOAD';

// One streaming PUT attempt. Signs with x-amz-content-sha256: UNSIGNED-PAYLOAD
// (S3 allows this over HTTPS) so the file body never has to be hashed or
// buffered. Content-Length is set via INTERNET_BUFFERS.dwBufferTotal and is NOT
// a signed header, so it doesn't affect the signature. Returns the S3 region
// on a 301/400 redirect via BucketRegion.
function TS3Client.PutOnce(const Bucket, Key, LocalFile: string;
  out StatusCode: Integer; out BucketRegion: string;
  Progress: TS3Progress; AbortedPtr: PBoolean): Boolean;
var
  amzDate, dateStamp, scope, canonicalHeaders, signedHeaders: string;
  canonicalRequest, stringToSign, authHeader, headers, host, uri: string;
  kDate, kRegion, kService, kSigning, sig: TBytes;
  hSession, hConnect, hRequest: HINTERNET;
  flags: DWORD;
  bufs: INTERNET_BUFFERS;
  fs: TFileStream;
  chunk: array[0..65535] of Byte;
  readCnt: Integer; written: DWORD;
  total, done, lastReport: Int64;
  statusBuf, statusLen, idx: DWORD;
begin
  Result := False; StatusCode := 0; BucketRegion := '';
  host := RegionHost;
  uri := '/' + Bucket + '/' + UriEncode(Key, False);
  UtcNowStamp(amzDate, dateStamp);

  signedHeaders := 'host;x-amz-content-sha256;x-amz-date';
  canonicalHeaders :=
    'host:' + host + #10 +
    'x-amz-content-sha256:' + UNSIGNED_PAYLOAD + #10 +
    'x-amz-date:' + amzDate + #10;

  // PUT, empty canonical query, payload hash = literal UNSIGNED-PAYLOAD.
  canonicalRequest :=
    'PUT' + #10 + uri + #10 + '' + #10 +
    canonicalHeaders + #10 + signedHeaders + #10 + UNSIGNED_PAYLOAD;

  scope := dateStamp + '/' + FRegion + '/s3/aws4_request';
  stringToSign :=
    'AWS4-HMAC-SHA256' + #10 + amzDate + #10 + scope + #10 +
    ToHex(SHA256Str(canonicalRequest));

  kDate    := HMACSHA256(StrToBytes('AWS4' + FSecret), StrToBytes(dateStamp));
  kRegion  := HMACSHA256(kDate, StrToBytes(FRegion));
  kService := HMACSHA256(kRegion, StrToBytes('s3'));
  kSigning := HMACSHA256(kService, StrToBytes('aws4_request'));
  sig      := HMACSHA256(kSigning, StrToBytes(stringToSign));

  authHeader :=
    'AWS4-HMAC-SHA256 Credential=' + FAccess + '/' + scope +
    ', SignedHeaders=' + signedHeaders + ', Signature=' + ToHex(sig);

  headers :=
    'x-amz-date: ' + amzDate + #13#10 +
    'x-amz-content-sha256: ' + UNSIGNED_PAYLOAD + #13#10 +
    'Authorization: ' + authHeader + #13#10;

  fs := TFileStream.Create(LocalFile, fmOpenRead or fmShareDenyWrite);
  try
    total := fs.Size;
    hSession := InternetOpen('fpcs3/1.0', INTERNET_OPEN_TYPE_PRECONFIG, nil, nil, 0);
    if hSession = nil then Exit;
    try
      hConnect := InternetConnect(hSession, PChar(host), INTERNET_DEFAULT_HTTPS_PORT,
        nil, nil, INTERNET_SERVICE_HTTP, 0, 0);
      if hConnect = nil then Exit;
      try
        flags := INTERNET_FLAG_SECURE or INTERNET_FLAG_RELOAD or
                 INTERNET_FLAG_NO_CACHE_WRITE or INTERNET_FLAG_NO_AUTO_REDIRECT;
        hRequest := HttpOpenRequest(hConnect, 'PUT', PChar(uri), nil, nil, nil, flags, 0);
        if hRequest = nil then Exit;
        try
          FillChar(bufs, SizeOf(bufs), 0);
          bufs.dwStructSize := SizeOf(bufs);
          bufs.lpcszHeader := PChar(headers);
          bufs.dwHeadersLength := Length(headers);
          // ponytail: dwBufferTotal is a 32-bit DWORD, so a single-PUT upload
          // tops out at 4GB. For >4GB, switch to S3 multipart upload.
          bufs.dwBufferTotal := DWORD(total);   // Content-Length (unsigned header)

          if not HttpSendRequestEx(hRequest, @bufs, nil, 0, 0) then Exit;

          done := 0; lastReport := 0;
          repeat
            readCnt := fs.Read(chunk, SizeOf(chunk));
            if readCnt <= 0 then Break;
            if not InternetWriteFile(hRequest, @chunk[0], readCnt, written) then Exit;
            Inc(done, written);
            if Assigned(Progress) and (done - lastReport >= 1024*1024) then
            begin
              lastReport := done;
              if Progress(done, total) then
              begin
                if AbortedPtr <> nil then AbortedPtr^ := True;
                Exit;   // finally-blocks close the handles => aborted upload
              end;
            end;
          until readCnt < SizeOf(chunk);

          if not HttpEndRequest(hRequest, nil, 0, 0) then Exit;

          statusBuf := 0; statusLen := SizeOf(statusBuf); idx := 0;
          if HttpQueryInfo(hRequest, HTTP_QUERY_STATUS_CODE or HTTP_QUERY_FLAG_NUMBER,
               @statusBuf, statusLen, idx) then
            StatusCode := statusBuf;
          BucketRegion := QueryHeader(hRequest, 'x-amz-bucket-region');
          Result := True;
        finally
          InternetCloseHandle(hRequest);
        end;
      finally
        InternetCloseHandle(hConnect);
      end;
    finally
      InternetCloseHandle(hSession);
    end;
  finally
    fs.Free;
  end;
end;

function TS3Client.PutObjectFromFile(const Bucket, Key, LocalFile: string;
  out Status: Integer; Progress: TS3Progress; AbortedPtr: PBoolean): Boolean;
var br: string; attempt: Integer; aborted: Boolean;
begin
  Result := False;
  if AbortedPtr <> nil then AbortedPtr^ := False;
  for attempt := 0 to 1 do
  begin
    aborted := False;
    PutOnce(Bucket, Key, LocalFile, Status, br, Progress, @aborted);
    if aborted then
    begin
      if AbortedPtr <> nil then AbortedPtr^ := True;
      Exit(False);
    end;
    if ((Status = 301) or (Status = 400)) and (br <> '') and (br <> FRegion) then
    begin
      FRegion := br;
      Continue;                 // learned real region — retry once
    end;
    Break;
  end;
  Result := (Status = 200);
end;

function TS3Client.DeleteObject(const Bucket, Key: string; out Status: Integer): Boolean;
var ms: TMemoryStream; br, uri: string; attempt: Integer;
begin
  Result := False;
  uri := '/' + Bucket + '/' + UriEncode(Key, False);
  for attempt := 0 to 1 do
  begin
    ms := TMemoryStream.Create;
    try
      SignedRequest('DELETE', RegionHost, uri, '', nil, ms, Status, br);
    finally ms.Free; end;
    if ((Status = 301) or (Status = 400)) and (br <> '') and (br <> FRegion) then
      FRegion := br             // learned real region — retry once
    else
      Break;
  end;
  Result := (Status = 200) or (Status = 204);  // S3 returns 204 on delete
end;

function TS3Client.CreateFolder(const Bucket, Key: string; out Status: Integer): Boolean;
var ms: TMemoryStream; br, uri: string; attempt: Integer;
begin
  Result := False;
  uri := '/' + Bucket + '/' + UriEncode(Key, False);
  for attempt := 0 to 1 do
  begin
    ms := TMemoryStream.Create;
    try
      // Empty payload => SignedRequest uses EMPTY_SHA256; PUT creates the marker.
      SignedRequest('PUT', RegionHost, uri, '', nil, ms, Status, br);
    finally ms.Free; end;
    if ((Status = 301) or (Status = 400)) and (br <> '') and (br <> FRegion) then
      FRegion := br             // learned real region — retry once
    else
      Break;
  end;
  Result := (Status = 200);
end;

end.
