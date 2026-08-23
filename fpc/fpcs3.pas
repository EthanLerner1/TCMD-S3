unit fpcs3;
{$mode objfpc}{$H+}
// Minimal AWS S3 client for FPC: SigV4 signing + HTTPS via wininet (no OpenSSL).
// Enough to replace the Data.Cloud.AmazonAPI calls the plugin needs.
interface

uses SysUtils, Classes, fpcs3_hash;

type
  TS3Client = class
  private
    FAccess, FSecret, FRegion: string;
    // Core signed request. Payload is the request body (empty for GET/DELETE).
    // Response body is written raw to RespStream. On a region redirect the
    // actual bucket region is returned in BucketRegion so the caller can retry.
    function SignedRequest(const Method, Host, CanonicalUri, CanonicalQuery: string;
      const Payload: TBytes; RespStream: TStream;
      out StatusCode: Integer; out BucketRegion: string): Boolean;
  public
    constructor Create(const AAccess, ASecret, ARegion: string);
    property Region: string read FRegion write FRegion;
    function RegionHost: string;
    function ListBucketsXML(out Body: string; out Status: Integer): Boolean;
    // These auto-detect and follow the bucket's real region on a 301/400.
    function ListObjectsXML(const Bucket, Prefix: string;
      out Body: string; out Status: Integer): Boolean;
    function GetObjectToFile(const Bucket, Key, LocalFile: string;
      out Status: Integer): Boolean;
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
  out StatusCode: Integer; out BucketRegion: string): Boolean;
var
  amzDate, dateStamp, scope, canonicalHeaders, signedHeaders: string;
  canonicalRequest, stringToSign, authHeader, headers, payloadHash: string;
  kDate, kRegion, kService, kSigning, sig: TBytes;
  hSession, hConnect, hRequest: HINTERNET;
  flags: DWORD;
  buf: array[0..16383] of Byte;
  bytesRead: DWORD;
  statusBuf, statusLen, idx: DWORD;
  optPtr: Pointer; optLen: DWORD;
begin
  Result := False; StatusCode := 0; BucketRegion := '';
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

        while InternetReadFile(hRequest, @buf[0], SizeOf(buf), bytesRead) and (bytesRead > 0) do
          RespStream.WriteBuffer(buf[0], bytesRead);
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
  out Status: Integer): Boolean;
var fs: TFileStream; ms: TMemoryStream; br, uri: string; attempt: Integer;
begin
  Result := False;
  uri := '/' + Bucket + '/' + UriEncode(Key, False);
  for attempt := 0 to 1 do
  begin
    ms := TMemoryStream.Create;
    try
      Result := SignedRequest('GET', RegionHost, uri, '', nil, ms, Status, br);
      if ((Status = 301) or (Status = 400)) and (br <> '') and (br <> FRegion) then
      begin
        FRegion := br;
        Continue;               // retry with correct region, don't write file yet
      end;
      if Status = 200 then
      begin
        fs := TFileStream.Create(LocalFile, fmCreate);
        try ms.Position := 0; fs.CopyFrom(ms, ms.Size); finally fs.Free; end;
      end;
    finally ms.Free; end;
    Break;
  end;
end;

end.
