unit A2600.Supercharger;

interface

uses
  System.SysUtils, Core.Snapshots;

type
  // Six KiB RAM, two 2K windows and address-latched delayed writes.
  // Binary tape blocks are loaded by our own small bootstrap, without a BIOS dump.
  TA2600Supercharger = class
  private
    FTape: TBytes;
    FRAM: array[0..6143] of Byte;
    FBoot: array[0..2047] of Byte;
    FWindows: array[0..1] of Integer;
    FConfig, FLatch, FLoadNumber: Byte;
    FEnabled, FPending: Boolean;
    FPrevious: Word;
    FDistinct, FWriteAt: UInt64;
    procedure Configure(Value: Byte);
    procedure LoadBlock(Number: Byte);
    procedure BuildBootstrap(Control, StartLow, StartHigh: Byte);
  public
    constructor Create(const Tape: TBytes);
    procedure Reset;
    procedure Access(Address: Word);
    procedure Observe(Address: Word; Value: Byte);
    function Read(Address: Word): Byte;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Classes;

constructor TA2600Supercharger.Create(const Tape: TBytes);
begin
  inherited Create;
  if Length(Tape) = 6144 then
  begin
    // Headerless RAM dumps use linear 2K banks with bank 0 below bank 2.
    SetLength(FTape, 8448);
    Move(Tape[0], FTape[0], 6144);
    FTape[8192] := Tape[6140];
    FTape[8193] := Tape[6141];
    FTape[8194] := $0F;
    FTape[8195] := 24;
    if ((FTape[8192] = $FF) and (FTape[8193] = $FF)) or
      ((FTape[8192] = 0) and (FTape[8193] = 0)) then
    begin
      // Old linear RAM dumps can omit the cartridge vectors as well as the
      // tape header. Recognize an explicit cold-entry stub in RAM bank 2.
      if not (((Tape[4096] = $78) and (Tape[4097] = $D8)) or
        ((Tape[4096] = $D8) and (Tape[4097] = $78))) then
        raise EReadError.Create('Headerless Supercharger dump needs a load entry point');
      FTape[8192] := 0;
      FTape[8193] := $F0;
      FTape[8194] := $09;
    end;
    for var i := 0 to 23 do
      FTape[8208 + i] := ((i mod 8) shl 2) or (i div 8);
  end
  else
  begin
    if (Length(Tape) = 0) or (Length(Tape) mod 8448 <> 0) then
      raise EReadError.Create('Truncated Supercharger tape block');
    FTape := Copy(Tape);
  end;
  Reset;
end;

procedure TA2600Supercharger.Configure(Value: Byte);
const
  Lower: array[0..7] of Integer = (2, 0, 2, 0, 2, 1, 2, 1);
  Upper: array[0..7] of Integer = (3, 3, 0, 2, 3, 3, 1, 2);
begin
  FConfig := Value;
  FEnabled := Value and 2 <> 0;
  FWindows[0] := Lower[(Value shr 2) and 7];
  FWindows[1] := Upper[(Value shr 2) and 7];
end;

procedure TA2600Supercharger.BuildBootstrap(Control, StartLow, StartHigh: Byte);
var
  P: Integer;

  procedure Emit(Value: Byte);
  begin
    FBoot[P] := Value;
    Inc(P);
  end;

  procedure Store(Address, Value: Byte);
  begin
    Emit($A9);
    Emit(Value);
    Emit($85);
    Emit(Address);
  end;

begin
  FillChar(FBoot, SizeOf(FBoot), $EA);
  // Warm entry: the Supercharger ABI passes the next load ID in RIOT $FA.
  P := 0;
  Emit($A5);
  Emit($FA);
  Emit($85);
  Emit($80);
  Emit($4C);
  Emit($50);
  Emit($F8);
  // Cold entry alone clears all RIOT RAM and TIA registers.
  P := $20;
  Emit($78);
  Emit($D8);
  Emit($A2);
  Emit($00);
  Emit($A9);
  Emit($00);
  Emit($95);
  Emit($00);
  Emit($E8);
  Emit($D0);
  Emit($FB);
  Store($80, FTape[8197]);
  Emit($4C);
  Emit($50);
  Emit($F8);
  // Fetching $F850 loads the requested binary block before executing this code.
  P := $50;
  Emit($78);
  Emit($D8);
  Emit($A9);
  Emit($00);
  Emit($A2);
  Emit($28);
  Emit($95);
  Emit($04);
  Emit($CA);
  Emit($10);
  Emit($FB);
  Emit($A2);
  Emit($1C);
  Emit($95);
  Emit($81);
  Emit($CA);
  Emit($10);
  Emit($FB);
  // Preserve $9E..$F9 between loads; games keep their persistent state there.
  Store($80, Control);
  Store($FA, $CD);
  Store($FB, $F8);
  Store($FC, $FF);
  Store($FD, $4C);
  Store($FE, StartLow);
  Store($FF, StartHigh);
  Emit($CD);
  Emit(Control);
  Emit($F0);
  Emit($A9);
  Emit($9A);
  Emit($A2);
  Emit($FF);
  Emit($A0);
  Emit($00);
  Emit($9A);
  Emit($4C);
  Emit($FA);
  Emit($00);
  FBoot[$7FC] := $20;
  FBoot[$7FD] := $F8;
  FBoot[$7FE] := 0;
  FBoot[$7FF] := $F8;
end;

procedure TA2600Supercharger.LoadBlock(Number: Byte);
begin
  for var Block := 0 to Length(FTape) div 8448 - 1 do
  begin
    var Base := Block * 8448;
    var Header := Base + 8192;
    if FTape[Header + 5] <> Number then
      Continue;
    var Pages := Integer(FTape[Header + 3]);
    if Pages > 24 then
      raise EReadError.Create('Invalid Supercharger page count');
    for var i := 0 to Pages - 1 do
    begin
      var Map := FTape[Header + 16 + i];
      var Bank := Map and 3;
      if Bank >= 3 then
        raise EReadError.Create('Supercharger page targets ROM');
      var Page := (Map shr 2) and 7;
      Move(FTape[Base + i * 256], FRAM[Bank * 2048 + Page * 256], 256);
    end;
    BuildBootstrap(FTape[Header + 2], FTape[Header], FTape[Header + 1]);
    Exit;
  end;
  raise EReadError.CreateFmt('Supercharger load %d is absent', [Number]);
end;

procedure TA2600Supercharger.Reset;
begin
  FillChar(FRAM, SizeOf(FRAM), 0);
  FPending := False;
  FDistinct := 0;
  FWriteAt := 0;
  FPrevious := $FFFF;
  FLatch := 0;
  FLoadNumber := 0;
  Configure(0);
  LoadBlock(FTape[8197]);
end;

procedure TA2600Supercharger.Access(Address: Word);
begin
  if Address <> FPrevious then
    Inc(FDistinct);
  FPrevious := Address;
  if FPending and (FDistinct > FWriteAt) then
    FPending := False;
  if Address and $1000 = 0 then
    Exit;
  if (Address and $0F00 = 0) and (not FEnabled or not FPending) then
  begin
    FLatch := Address and $FF;
    FWriteAt := FDistinct + 5;
    FPending := True;
  end
  else if Address = $1FF8 then
  begin
    FPending := False;
    Configure(FLatch);
  end
  else if FEnabled and FPending and (FDistinct = FWriteAt) then
  begin
    // A12 selects the cartridge; accesses below it still advance the latch.
    if Address and $1000 <> 0 then
    begin
      var Bank := FWindows[(Address shr 11) and 1];
      if Bank < 3 then
        FRAM[Bank * 2048 + (Address and $7FF)] := FLatch;
    end;
    FPending := False;
  end;
end;

procedure TA2600Supercharger.Observe(Address: Word; Value: Byte);
begin
  if Address = $80 then
    FLoadNumber := Value;
end;

function TA2600Supercharger.Read(Address: Word): Byte;
begin
  var Bank := FWindows[(Address shr 11) and 1];
  if Bank = 3 then
  begin
    if Address = $1850 then
    begin
      // The physical loader uses bank 1 page 7 as its loading display buffer.
      FillChar(FRAM[2048 + 7 * 256], 256, 0);
      LoadBlock(FLoadNumber);
    end;
    Result := FBoot[Address and $7FF];
  end
  else
    Result := FRAM[Bank * 2048 + (Address and $7FF)];
end;

procedure TA2600Supercharger.SerializeState(State: TStateArchive);
begin
  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FBoot, SizeOf(FBoot));
  State.Field(FConfig, SizeOf(FConfig));
  State.Field(FLatch, SizeOf(FLatch));
  State.Field(FLoadNumber, SizeOf(FLoadNumber));
  State.Field(FPending, SizeOf(FPending));
  State.Field(FPrevious, SizeOf(FPrevious));
  State.Field(FDistinct, SizeOf(FDistinct));
  State.Field(FWriteAt, SizeOf(FWriteAt));
  Configure(FConfig);
end;

end.

