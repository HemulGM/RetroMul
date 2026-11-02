unit PSP.PRX;

// Independently authored envelope decoder: immutable input -> normalized
// metadata -> authenticated KIRK envelope -> bounded ELF decompression.
// The envelopes' layouts are the PSP Developer Wiki's (Keys, Kirk), the
// fields' routing as uOFW's firmware analysis describes it, both checked
// against real modules (header SHA-1 and KIRK authentication); the numeric
// data is in PSP.Crypto.Keys.
interface

uses
  System.SysUtils, System.Classes;

type
  EPSPPRX = class(EReadError);

function DecryptPSPPRX(const Data: TBytes): TBytes;

// scePauth payloads use the same envelope, but produce arbitrary data, not ELF.
function DecryptPSPPauth(const Data, CallerKey: TBytes; SecondEntry: Boolean): TBytes;

implementation

uses
  System.ZLib, PSP.Crypto.Keys, PSP.Crypto.Kirk;

const
  HeaderSize = $150;
  MaxModule = 64 * 1024 * 1024;

function WordAt(const D: TBytes; P: Integer): Cardinal;
begin
  if (P < 0) or (Int64(P) + 4 > Length(D)) then
    raise EPSPPRX.Create('PRX: truncated word');
  Result := D[P] or (Cardinal(D[P + 1]) shl 8) or (Cardinal(D[P + 2]) shl 16) or (Cardinal(D[P + 3]) shl 24);
end;

procedure Put(var Dest: TBytes; At: Integer; const Source: TBytes; From, Count: Integer);
begin
  if (At < 0) or (From < 0) or (Count < 0) or (Int64(At) + Count > Length(Dest)) or (Int64(From) + Count >
    Length(Source)) then
    raise EPSPPRX.Create('PRX: invalid metadata extent');
  if Count > 0 then
    Move(Source[From], Dest[At], Count);
end;

function XorBytes(const A: TBytes; const Key: TBytes; KeyAt: Integer): TBytes;
begin
  if (KeyAt < 0) or (KeyAt + Length(A) > Length(Key)) then
    raise EPSPPRX.Create('PRX: invalid key span');
  SetLength(Result, Length(A));
  for var I := 0 to High(A) do
    Result[I] := A[I] xor Key[KeyAt + I];
end;

// Old envelopes publish the 144-byte schedule itself. The SHA-1 covers the
// schedule's first 20 bytes plus the rearranged metadata after its digest.
function LegacyEnvelope(const D: TBytes; const SeedName: string; Slot: Integer; ExtraCBC: Boolean): TBytes;
begin
  var Schedule := PSPPrxSeed(SeedName);
  if Length(Schedule) <> $90 then
    raise EPSPPRX.Create('PRX: missing legacy schedule');
  var H: TBytes;
  SetLength(H, HeaderSize);
  Put(H, 0, D, $D0, $80);
  Put(H, $80, D, $80, $50);
  Put(H, $D0, D, 0, $80);
  if ExtraCBC then
    Put(H, $10, PSPKirk7(Copy(H, $10, $A0), Slot), 0, $A0);
  var Expected := Copy(H, 4, 20);
  Put(H, 4, Schedule, 0, 20);
  if not PSPDigestEqual(PSPSHA1(H, 4, HeaderSize - 4), Expected) then
    raise EPSPPRX.Create('PRX: legacy header SHA-1 rejected');
  var Inner := XorBytes(PSPKirk7(XorBytes(Copy(H, $40, $70), Schedule, $14), Slot), Schedule, $20);
  SetLength(Result, Length(D) - $40);
  Put(Result, 0, Inner, 0, $70);
  Put(Result, $70, H, $B0, $A0);
  Put(Result, $110, D, HeaderSize, Length(D) - HeaderSize);
end;

// Modern game envelopes derive nine CBC blocks from a 16-byte tag seed,
// replacing the first byte with the block number. Layout 6 additionally
// preserves the 32-byte tail of the KIRK ECDSA signatures.
function GameEnvelope(const D: TBytes; Tag: Cardinal; Signed: Boolean; Pauth: Boolean = False; const CallerKey: TBytes = nil): TBytes;
begin
  var Slot := $5D;
  if Pauth then
    Slot := $47;
  var Seed := PSPPrxSeed('key_' + IntToHex(Tag, 8));
  if Length(Seed) <> 16 then
    raise EPSPPRX.CreateFmt('PRX: unknown seed for tag %.8x', [Tag]);
  var Expanded: TBytes;
  SetLength(Expanded, $90);
  for var B := 0 to 8 do
  begin
    Put(Expanded, B * 16, Seed, 0, 16);
    Expanded[B * 16] := B;
  end;
  var Schedule := PSPKirk7(Expanded, Slot);
  var Mask: TBytes;
  var Weave: TBytes;
  if Pauth then
  begin
    if Length(CallerKey) <> 16 then
      raise EPSPPRX.Create('Pauth: invalid caller key');
    Mask := PSPPrxSeed('pauthXorKey');
    if Length(Mask) <> 16 then
      raise EPSPPRX.Create('Pauth: missing whitening data');
    for var I := 0 to High(Schedule) do
      Schedule[I] := Schedule[I] xor CallerKey[I and 15];
    SetLength(Weave, $50);
    Put(Weave, 0, D, $80, $30);
    Put(Weave, $30, D, $C0, $10);
    Put(Weave, $40, D, $12C, $10);
    for var I := 0 to High(Weave) do
      Weave[I] := Weave[I] xor Mask[I and 15] xor CallerKey[I and 15];
    Weave := PSPKirk7(Weave, Slot);
  end;
  var ZeroEnd := $12C;
  if Signed then
    ZeroEnd := $10C;
  var ZeroStart := $D4;
  if Pauth then
  begin
    if (D[$D4] <> 0) and (D[$D4] <> $80) then
      raise EPSPPRX.Create('Pauth: invalid metadata flag');
    Inc(ZeroStart);
  end;
  for var I := ZeroStart to ZeroEnd - 1 do
    if D[I] <> 0 then
      raise EPSPPRX.Create('PRX: reserved metadata is not zero');
  var H: TBytes;
  SetLength(H, HeaderSize);
  Put(H, 0, D, $D0, $5C);
  Put(H, $5C, D, $140, $10);
  Put(H, $6C, D, $12C, $14);
  Put(H, $80, D, $80, $30);
  Put(H, $B0, D, $C0, $10);
  Put(H, $C0, D, $B0, $10);
  Put(H, $D0, D, 0, $80);
  if Pauth then
  begin
    Put(H, $6C, Weave, $40, $10);
    Put(H, $80, Weave, 0, $30);
    Put(H, $B0, Weave, $30, $10);
    for var I := $5C to $BB do
      H[I] := H[I] xor Mask[(I - $5C) and 15];
  end;
  Put(H, $5C, PSPKirk7(Copy(H, $5C, $60), Slot), 0, $60);
  var Expected := Copy(H, $6C, 20);
  var Salt := Copy(H, $5C, 16);
  var Tail := Copy(H, $3C, 32);
  Put(H, 4, D, $D0, 4);
  Put(H, 8, Schedule, 0, 16);
  FillChar(H[$18], $58, 0);
  if Pauth and (D[$D4] = $80) then
    H[$18] := $80;
  if Signed then
    Put(H, $50, Tail, 0, 32);
  Put(H, $70, Salt, 0, 16);
  if not PSPDigestEqual(PSPSHA1(H, 4, HeaderSize - 4), Expected) then
    raise EPSPPRX.Create('PRX: game header SHA-1 rejected');
  var Inner := XorBytes(PSPKirk7(XorBytes(Copy(H, $80, $40), Schedule, $10), Slot), Schedule, $50);
  SetLength(Result, Length(D) - $40);
  Put(Result, 0, Inner, 0, $40);
  if Signed then
  begin
    Put(Result, $40, Tail, 0, 32);
    Result[$64] := 1;
  end;
  Result[$60] := 1;
  Put(Result, $70, H, $C0, 16);
  Put(Result, $90, H, $D0, $80);
  Put(Result, $110, D, HeaderSize, Length(D) - HeaderSize);
end;

function DecryptPSPPauth(const Data, CallerKey: TBytes; SecondEntry: Boolean): TBytes;
begin
  if (Length(Data) < HeaderSize) or (Length(Data) > MaxModule) then
    raise EPSPPRX.Create('Pauth: invalid envelope size');
  var Tag := WordAt(Data, $D0);
  if SecondEntry then
  begin
    if Tag <> $2FD313F0 then
      raise EPSPPRX.CreateFmt('Pauth: unsupported tag %.8x', [Tag]);
  end
  else if (Tag <> $2FD311F0) and (Tag <> $2FD312F0) then
    raise EPSPPRX.CreateFmt('Pauth: unsupported tag %.8x', [Tag]);
  Result := PSPKirk1(GameEnvelope(Data, Tag, False, True, CallerKey));
end;

function Unpack(const Plain: TBytes; ElfSize: Cardinal): TBytes;
begin
  if (Length(Plain) >= 2) and (Plain[0] = $1F) and (Plain[1] = $8B) then
  begin
    var Input := TBytesStream.Create(Plain);
    var Output := TMemoryStream.Create;
    try
      var Z := TZDecompressionStream.Create(Input, 31);
      try
        try
          var Buffer: array[0..16383] of Byte;
          while True do
          begin
            var N := Z.Read(Buffer, SizeOf(Buffer));
            if N = 0 then
              Break;
            if Output.Size + N > ElfSize then
              raise EPSPPRX.Create('PRX: decompression exceeds declared ELF size');
            Output.WriteBuffer(Buffer, N);
          end;
        except
          on E: EZDecompressionError do
            raise EPSPPRX.Create('PRX: invalid gzip payload');
        end;
      finally
        Z.Free;
      end;
      SetLength(Result, Output.Size);
      if Length(Result) > 0 then
        Move(Output.Memory^, Result[0], Length(Result));
    finally
      Output.Free;
      Input.Free;
    end;
    if Cardinal(Length(Result)) <> ElfSize then
      raise EPSPPRX.Create('PRX: decompressed size mismatch');
  end
  else
    Result := Plain;
  if (Length(Result) < 52) or (WordAt(Result, 0) <> $464C457F) then
    raise EPSPPRX.Create('PRX: payload is not ELF (unsupported compression)');
  if Cardinal(Length(Result)) <> ElfSize then
    raise EPSPPRX.Create('PRX: ELF size mismatch');
end;

function DecryptPSPPRX(const Data: TBytes): TBytes;
begin
  var D := Data;
  for var Wrapper := 0 to 3 do
  begin
    if (Length(D) < 8) or (WordAt(D, 0) <> $4543537E) then
      Break;
    var Skip := WordAt(D, 4);
    if (Skip < 8) or (Skip >= Cardinal(Length(D))) then
      raise EPSPPRX.Create('PRX: invalid SCE wrapper');
    D := Copy(D, Skip, Length(D) - Integer(Skip));
  end;
  if (Length(D) >= 52) and (WordAt(D, 0) = $464C457F) then
    Exit(D);
  if (Length(D) < HeaderSize) or (Length(D) > MaxModule) or (WordAt(D, 0) <> $5053507E) then
    raise EPSPPRX.Create('PRX: invalid or truncated envelope');
  var ElfSize := WordAt(D, $28);
  if (ElfSize < 52) or (ElfSize > MaxModule) then
    raise EPSPPRX.Create('PRX: invalid declared ELF size');
  var Tag := WordAt(D, $D0);
  var Envelope: TBytes;
  case Tag of
    $00000000:
      Envelope := LegacyEnvelope(D, 'g_key0', $42, False);
    $02000000:
      Envelope := LegacyEnvelope(D, 'g_key2', $45, False);
    $03000000:
      Envelope := LegacyEnvelope(D, 'g_key3', $46, False);
    $08000000:
      Envelope := LegacyEnvelope(D, 'g_keyEBOOT1xx', $4B, False);
    $C0CB167C:
      Envelope := LegacyEnvelope(D, 'g_keyEBOOT2xx', $5D, True);
  else
    if (Tag and $FFFF00FF = $D91600F0) and ((Tag and $FF00) < $8000) then
      Envelope := GameEnvelope(D, Tag, False)
    else if (Tag = $D91680F0) or (Tag = $D91681F0) then
      Envelope := GameEnvelope(D, Tag, True)
    else
      raise EPSPPRX.CreateFmt('PRX: unsupported tag %.8x', [Tag]);
  end;
  if WordAt(Envelope, $70) <> WordAt(D, $B0) then
    raise EPSPPRX.Create('PRX: payload size mismatch');
  Result := Unpack(PSPKirk1(Envelope), ElfSize);
end;

end.

