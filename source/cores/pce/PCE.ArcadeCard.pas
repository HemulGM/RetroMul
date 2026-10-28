unit PCE.ArcadeCard;

interface

uses
  System.SysUtils, Core.Snapshots;

type
  TPCEArcadePort = record
    Base: Cardinal;
    Offset, Increment: Word;
    Control: Byte;
  end;

  TPCEArcadeCard = class
  private
    FRAM: TBytes;
    FPorts: array[0..3] of TPCEArcadePort;
    FValue: Cardinal;
    FShift, FRotate: Byte;
    function Address(Port: Integer): Integer;
    procedure AutoIncrement(Port: Integer);
    procedure AddOffset(Port: Integer);
  public
    constructor Create;
    procedure Reset;
    function Read(Address: Word): Byte;
    procedure Write(Address: Word; Value: Byte);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

constructor TPCEArcadeCard.Create;
begin
  inherited;
  SetLength(FRAM, $200000);
  Reset;
end;

procedure TPCEArcadeCard.Reset;
begin
  FillChar(FPorts, SizeOf(FPorts), 0);
  FValue := 0;
  FShift := 0;
  FRotate := 0;
end;

function TPCEArcadeCard.Address(Port: Integer): Integer;
begin
  var A := Int64(FPorts[Port].Base);
  if FPorts[Port].Control and 2 <> 0 then
  begin
    Inc(A, FPorts[Port].Offset);
    if FPorts[Port].Control and 8 <> 0 then
      Dec(A, $10000);
  end;
  Result := A and $1FFFFF;
end;

procedure TPCEArcadeCard.AutoIncrement(Port: Integer);
begin
  if FPorts[Port].Control and 1 = 0 then
    Exit;
  if FPorts[Port].Control and $10 <> 0 then
    FPorts[Port].Base := (FPorts[Port].Base + Cardinal(FPorts[Port].Increment)) and $FFFFFF
  else
    FPorts[Port].Offset := (Integer(FPorts[Port].Offset) + FPorts[Port].Increment) and $FFFF;
end;

procedure TPCEArcadeCard.AddOffset(Port: Integer);
begin
  var A := Int64(FPorts[Port].Base) + FPorts[Port].Offset;
  if FPorts[Port].Control and 8 <> 0 then
    Dec(A, $10000);
  FPorts[Port].Base := A and $FFFFFF;
end;

function TPCEArcadeCard.Read(Address: Word): Byte;
begin
  Address := Address and $1FF;
  Result := $FF;
  if Address < $80 then
  begin
    var P := (Address shr 4) and 3;
    case Address and 15 of
      0, 1:
        begin
          Result := FRAM[Self.Address(P)];
          AutoIncrement(P);
        end;
      2..4:
        Result := (FPorts[P].Base shr ((Address - 2) * 8 and 31)) and 255;
      5:
        Result := FPorts[P].Offset and 255;
      6:
        Result := FPorts[P].Offset shr 8;
      7:
        Result := FPorts[P].Increment and 255;
      8:
        Result := FPorts[P].Increment shr 8;
      9:
        Result := FPorts[P].Control;
      10:
        Result := 0;
    end;
  end
  else
    case Address of
      $E0..$E3:
        Result := (FValue shr ((Address - $E0) * 8)) and 255;
      $E4:
        Result := FShift;
      $E5:
        Result := FRotate;
      $FE:
        Result := $10;
      $FF:
        Result := $51;
    end;
end;

procedure TPCEArcadeCard.Write(Address: Word; Value: Byte);
begin
  Address := Address and $1FF;
  if Address < $80 then
  begin
    var P := (Address shr 4) and 3;
    case Address and 15 of
      0, 1:
        begin
          FRAM[Self.Address(P)] := Value;
          AutoIncrement(P);
        end;
      2..4:
        begin
          var Shift := ((Address and 15) - 2) * 8;
          FPorts[P].Base := (FPorts[P].Base and not (Cardinal(255) shl Shift)) or (Cardinal(Value) shl Shift);
        end;
      5:
        begin
          FPorts[P].Offset := (FPorts[P].Offset and $FF00) or Value;
          if FPorts[P].Control and $60 = $20 then
            AddOffset(P);
        end;
      6:
        begin
          FPorts[P].Offset := (FPorts[P].Offset and 255) or (Word(Value) shl 8);
          if FPorts[P].Control and $60 = $40 then
            AddOffset(P);
        end;
      7:
        FPorts[P].Increment := (FPorts[P].Increment and $FF00) or Value;
      8:
        FPorts[P].Increment := (FPorts[P].Increment and 255) or (Word(Value) shl 8);
      9:
        FPorts[P].Control := Value and $7F;
      10:
        if FPorts[P].Control and $60 = $60 then
          AddOffset(P);
    end;
  end
  else
    case Address of
      $E0..$E3:
        begin
          var Shift := (Address - $E0) * 8;
          FValue := (FValue and not (Cardinal(255) shl Shift)) or (Cardinal(Value) shl Shift);
        end;
      $E4, $E5:
        begin
          var Shift := Value and 15;
          if Address = $E4 then
            FShift := Value
          else
            FRotate := Value;
          if Shift = 0 then
            Exit;
          if Shift < 8 then
          begin
            if Address = $E4 then
              FValue := FValue shl Shift
            else
              FValue := (FValue shl Shift) or (FValue shr (32 - Shift));
          end
          else
          begin
            Shift := 16 - Shift;
            if Address = $E4 then
              FValue := FValue shr Shift
            else
              FValue := (FValue shr Shift) or (FValue shl (32 - Shift));
          end;
        end;
    end;
end;

procedure TPCEArcadeCard.SerializeState(State: TStateArchive);
begin
  State.Field(FRAM[0], Length(FRAM));
  State.Field(FPorts, SizeOf(FPorts));
  State.Field(FValue, SizeOf(FValue));
  State.Field(FShift, SizeOf(FShift));
  State.Field(FRotate, SizeOf(FRotate));
end;

end.

