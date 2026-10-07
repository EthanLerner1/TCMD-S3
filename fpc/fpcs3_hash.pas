unit fpcs3_hash;
{$mode objfpc}{$H+}
// Self-contained SHA-256 + HMAC-SHA256 for AWS SigV4.
// FPC 3.2.2's hmac unit is MD5/SHA1 only, so we roll our own.
interface

type
  TBytes = array of Byte;

function SHA256(const Data: TBytes): TBytes;
function SHA256Str(const S: RawByteString): TBytes;
function HMACSHA256(const Key, Data: TBytes): TBytes;
function ToHex(const B: TBytes): string;
function StrToBytes(const S: RawByteString): TBytes;

implementation

const
  K: array[0..63] of Cardinal = (
    $428a2f98,$71374491,$b5c0fbcf,$e9b5dba5,$3956c25b,$59f111f1,$923f82a4,$ab1c5ed5,
    $d807aa98,$12835b01,$243185be,$550c7dc3,$72be5d74,$80deb1fe,$9bdc06a7,$c19bf174,
    $e49b69c1,$efbe4786,$0fc19dc6,$240ca1cc,$2de92c6f,$4a7484aa,$5cb0a9dc,$76f988da,
    $983e5152,$a831c66d,$b00327c8,$bf597fc7,$c6e00bf3,$d5a79147,$06ca6351,$14292967,
    $27b70a85,$2e1b2138,$4d2c6dfc,$53380d13,$650a7354,$766a0abb,$81c2c92e,$92722c85,
    $a2bfe8a1,$a81a664b,$c24b8b70,$c76c51a3,$d192e819,$d6990624,$f40e3585,$106aa070,
    $19a4c116,$1e376c08,$2748774c,$34b0bcb5,$391c0cb3,$4ed8aa4a,$5b9cca4f,$682e6ff3,
    $748f82ee,$78a5636f,$84c87814,$8cc70208,$90befffa,$a4506ceb,$bef9a3f7,$c67178f2);

function RoR(x: Cardinal; n: Byte): Cardinal; inline;
begin
  Result := (x shr n) or (x shl (32 - n));
end;

function SHA256(const Data: TBytes): TBytes;
var
  h0,h1,h2,h3,h4,h5,h6,h7: Cardinal;
  msg: TBytes;
  origLenBits: QWord;
  i, j, chunks: Integer;
  w: array[0..63] of Cardinal;
  a,b,c,d,e,f,g,hh,s0,s1,ch,maj,t1,t2: Cardinal;
  padLen: Integer;
begin
  h0:=$6a09e667; h1:=$bb67ae85; h2:=$3c6ef372; h3:=$a54ff53a;
  h4:=$510e527f; h5:=$9b05688c; h6:=$1f83d9ab; h7:=$5be0cd19;

  origLenBits := QWord(Length(Data)) * 8;
  // pad: append 0x80, then zeros until length ≡ 56 (mod 64), then 8-byte length
  padLen := 64 - ((Length(Data) + 9) mod 64);
  if padLen = 64 then padLen := 0;
  SetLength(msg, Length(Data) + 1 + padLen + 8);
  if Length(Data) > 0 then Move(Data[0], msg[0], Length(Data));
  msg[Length(Data)] := $80;
  for i := Length(Data)+1 to Length(Data)+padLen do msg[i] := 0;
  for i := 0 to 7 do
    msg[Length(msg)-1-i] := Byte((origLenBits shr (8*i)) and $FF);

  chunks := Length(msg) div 64;
  for i := 0 to chunks-1 do
  begin
    for j := 0 to 15 do
      w[j] := (Cardinal(msg[i*64 + j*4]) shl 24) or
              (Cardinal(msg[i*64 + j*4+1]) shl 16) or
              (Cardinal(msg[i*64 + j*4+2]) shl 8) or
               Cardinal(msg[i*64 + j*4+3]);
    for j := 16 to 63 do
    begin
      s0 := RoR(w[j-15],7) xor RoR(w[j-15],18) xor (w[j-15] shr 3);
      s1 := RoR(w[j-2],17) xor RoR(w[j-2],19) xor (w[j-2] shr 10);
      w[j] := w[j-16] + s0 + w[j-7] + s1;
    end;
    a:=h0; b:=h1; c:=h2; d:=h3; e:=h4; f:=h5; g:=h6; hh:=h7;
    for j := 0 to 63 do
    begin
      s1 := RoR(e,6) xor RoR(e,11) xor RoR(e,25);
      ch := (e and f) xor ((not e) and g);
      t1 := hh + s1 + ch + K[j] + w[j];
      s0 := RoR(a,2) xor RoR(a,13) xor RoR(a,22);
      maj := (a and b) xor (a and c) xor (b and c);
      t2 := s0 + maj;
      hh:=g; g:=f; f:=e; e:=d + t1; d:=c; c:=b; b:=a; a:=t1 + t2;
    end;
    inc(h0,a); inc(h1,b); inc(h2,c); inc(h3,d);
    inc(h4,e); inc(h5,f); inc(h6,g); inc(h7,hh);
  end;

  SetLength(Result, 32);
  for i := 0 to 3 do
  begin
    Result[i]    := Byte((h0 shr (24-8*i)) and $FF);
    Result[i+4]  := Byte((h1 shr (24-8*i)) and $FF);
    Result[i+8]  := Byte((h2 shr (24-8*i)) and $FF);
    Result[i+12] := Byte((h3 shr (24-8*i)) and $FF);
    Result[i+16] := Byte((h4 shr (24-8*i)) and $FF);
    Result[i+20] := Byte((h5 shr (24-8*i)) and $FF);
    Result[i+24] := Byte((h6 shr (24-8*i)) and $FF);
    Result[i+28] := Byte((h7 shr (24-8*i)) and $FF);
  end;
end;

function StrToBytes(const S: RawByteString): TBytes;
begin
  SetLength(Result, Length(S));
  if Length(S) > 0 then Move(S[1], Result[0], Length(S));
end;

function SHA256Str(const S: RawByteString): TBytes;
begin
  Result := SHA256(StrToBytes(S));
end;

function HMACSHA256(const Key, Data: TBytes): TBytes;
var
  bkey, o_key_pad, i_key_pad, inner, combined: TBytes;
  i: Integer;
begin
  if Length(Key) > 64 then
    bkey := SHA256(Key)
  else
    bkey := Copy(Key, 0, Length(Key));
  SetLength(bkey, 64); // zero-pad to block size (SetLength zero-fills growth)
  SetLength(o_key_pad, 64);
  SetLength(i_key_pad, 64);
  for i := 0 to 63 do
  begin
    o_key_pad[i] := bkey[i] xor $5c;
    i_key_pad[i] := bkey[i] xor $36;
  end;
  SetLength(combined, 64 + Length(Data));
  Move(i_key_pad[0], combined[0], 64);
  if Length(Data) > 0 then Move(Data[0], combined[64], Length(Data));
  inner := SHA256(combined);
  SetLength(combined, 64 + Length(inner));
  Move(o_key_pad[0], combined[0], 64);
  Move(inner[0], combined[64], Length(inner));
  Result := SHA256(combined);
end;

function ToHex(const B: TBytes): string;
const hexchars = '0123456789abcdef';
var i: Integer;
begin
  SetLength(Result, Length(B)*2);
  for i := 0 to Length(B)-1 do
  begin
    Result[i*2+1] := hexchars[(B[i] shr 4) + 1];
    Result[i*2+2] := hexchars[(B[i] and $F) + 1];
  end;
end;

end.
