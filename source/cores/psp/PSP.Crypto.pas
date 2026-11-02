unit PSP.Crypto;

// Guest crypto services; executable decoding is independently usable in PSP.PRX.
interface

uses
  PSP.Service;

type
  TPSPCrypto = class(TPSPService)
  private
    procedure Pauth(SecondEntry: Boolean);
    procedure hPauth1;
    procedure hPauth2;
  public
    procedure Register; override;
  end;

implementation

uses
  System.SysUtils, PSP.PRX, PSP.Types, PSP.HLE;

procedure TPSPCrypto.Pauth(SecondEntry: Boolean);
begin
  var Address := FHLE.Arg(0);
  var Size := FHLE.Arg(1);
  var OutSize := FHLE.Arg(2);
  var KeyAddr := FHLE.Arg(3);
  if (Size < $150) or (Size > 64 * 1024 * 1024) or not FMemory.Valid(Address, Size) or not FMemory.Valid(OutSize, 4) or
    not FMemory.Valid(KeyAddr, 16) or (OutSize = 0) or (KeyAddr = 0) then
  begin
    FHLE.Result($800001FF);
    Exit;
  end;
  var Data, Key: TBytes;
  SetLength(Data, Size);
  SetLength(Key, 16);
  FMemory.ReadBytes(Address, Data[0], Size);
  FMemory.ReadBytes(KeyAddr, Key[0], 16);
  try
    var Plain := DecryptPSPPauth(Data, Key, SecondEntry);
    FMemory.WriteBytes(Address, Plain[0], Length(Plain));
    FMemory.Write32(OutSize, Length(Plain));
    FHLE.Result(0);
  except
    on E: Exception do
    begin
      FHLE.Log('pauth: %s', [E.Message]);
      FMemory.Write32(OutSize, 0);
      FHLE.Result($80000108);
    end;
  end;
end;

procedure TPSPCrypto.hPauth1;
begin
  Pauth(False);
end;

procedure TPSPCrypto.hPauth2;
begin
  Pauth(True);
end;

procedure TPSPCrypto.Register;
begin
  for var LibName in ['scePauth', 'scePauth_driver'] do
  begin
    FHLE.Register(LibName, $F7AA47F6, 'scePauth_F7AA47F6', hPauth1);
    FHLE.Register(LibName, $98B83B5D, 'scePauth_98B83B5D', hPauth2);
  end;
end;

initialization
  RegisterPSPService(TPSPCrypto);
end.
