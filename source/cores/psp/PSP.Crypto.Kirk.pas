unit PSP.Crypto.Kirk;

// The KIRK operations the PRX envelope needs. Command 1 authenticates the
// complete envelope BEFORE releasing plaintext; command 7 is slot-key CBC.
interface

uses
  System.SysUtils, System.Classes;

type
  EPSPCrypto = class(EReadError);

function PSPKirk7(const Data: TBytes; Slot: Integer): TBytes;
function PSPKirk1(const Envelope: TBytes): TBytes;
function PSPSHA1(const Data: TBytes; Offset, Count: Integer): TBytes;
function PSPDigestEqual(const A, B: TBytes): Boolean;

implementation

uses
  System.Hash, PSP.AES, PSP.Crypto.Keys, PSP.Crypto.ECDSA;

function PSPSHA1(const Data: TBytes; Offset, Count: Integer): TBytes;
begin
  if (Offset < 0) or (Count < 0) or (Int64(Offset) + Count > Length(Data)) then
    raise EPSPCrypto.Create('SHA-1 extent outside input');
  var Hash := THashSHA1.Create;
  if Count > 0 then
    Hash.Update(Data[Offset], Count);
  Result := Hash.HashAsBytes;
end;

function PSPDigestEqual(const A, B: TBytes): Boolean;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  var Diff: Cardinal := 0;
  for var I := 0 to High(A) do
    Diff := Diff or (A[I] xor B[I]);
  Result := Diff = 0;
end;

function WordAt(const Data: TBytes; Offset: Integer): Cardinal;
begin
  Result := Data[Offset] or (Cardinal(Data[Offset + 1]) shl 8) or (Cardinal(Data[Offset + 2]) shl 16) or
    (Cardinal(Data[Offset + 3]) shl 24);
end;

function PSPKirk7(const Data: TBytes; Slot: Integer): TBytes;
begin
  Result := PSPAESDecrypt(Data, PSPKirkSlot(Slot));
end;

function PSPKirk1(const Envelope: TBytes): TBytes;
begin
  if (Length(Envelope) < $90) or (WordAt(Envelope, $60) <> 1) then
    raise EPSPCrypto.Create('KIRK1: invalid metadata');
  var Mode := WordAt(Envelope, $64);
  if Mode > 1 then
    raise EPSPCrypto.Create('KIRK1: unsupported signature mode');
  var Size := UInt64(WordAt(Envelope, $70));
  var Offset := UInt64(WordAt(Envelope, $74));
  var Aligned := (Size + 15) and not UInt64(15);
  if (Size = 0) or (Size > 64 * 1024 * 1024) or ($90 + Offset + Aligned > UInt64(Length(Envelope))) then
    raise EPSPCrypto.Create('KIRK1: invalid ciphertext extent');
  var EndAt := Integer($90 + Offset + Aligned);
  var Keys := PSPAESDecrypt(Copy(Envelope, 0, 32), PSPHex('98C940975C1D10E87FE60EA3FD03A8BA'));
  if Mode = 0 then
  begin
    var Mac: TPSPAES;
    Mac.Init(Copy(Keys, 16, 16));
    if not PSPDigestEqual(Mac.CMAC(Copy(Envelope, $60, $30)), Copy(Envelope, $20, 16)) then
      raise EPSPCrypto.Create('KIRK1: header CMAC rejected');
    if not PSPDigestEqual(Mac.CMAC(Copy(Envelope, $60, EndAt - $60)), Copy(Envelope, $30, 16)) then
      raise EPSPCrypto.Create('KIRK1: body CMAC rejected');
  end
  else
  begin
    if not PSPVerifyKirkSignature(PSPSHA1(Envelope, $60, $30), Copy(Envelope, $10, 40)) then
      raise EPSPCrypto.Create('KIRK1: header ECDSA rejected');
    if not PSPVerifyKirkSignature(PSPSHA1(Envelope, $60, EndAt - $60), Copy(Envelope, $38, 40)) then
      raise EPSPCrypto.Create('KIRK1: body ECDSA rejected');
  end;
  Result := PSPAESDecrypt(Copy(Envelope, Integer($90 + Offset), Integer(Aligned)), Copy(Keys, 0, 16));
  SetLength(Result, Integer(Size));
end;

end.
