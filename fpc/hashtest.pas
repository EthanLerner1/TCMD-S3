program hashtest;
{$mode objfpc}{$H+}
uses fpcs3_hash;

var fails: Integer = 0;

procedure Check(const name, got, want: string);
begin
  if got = want then
    writeln('OK   ', name)
  else
  begin
    writeln('FAIL ', name, LineEnding, '  got  ', got, LineEnding, '  want ', want);
    inc(fails);
  end;
end;

begin
  // SHA-256 known-answer vectors
  Check('sha256("")', ToHex(SHA256Str('')),
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  Check('sha256("abc")', ToHex(SHA256Str('abc')),
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  Check('sha256("abcdbcde...")',
    ToHex(SHA256Str('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')),
    '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
  // HMAC-SHA256 RFC 4231 test case 2: key="Jefe", data="what do ya want for nothing?"
  Check('hmac-sha256 rfc4231-2',
    ToHex(HMACSHA256(StrToBytes('Jefe'), StrToBytes('what do ya want for nothing?'))),
    '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843');

  writeln;
  if fails = 0 then writeln('ALL PASS') else writeln(fails, ' FAILED');
  Halt(fails);
end.
