unit ZX.AM29F040;

interface

uses
  System.SysUtils, Core.Snapshots;

type
  // AMD command protocol, matching the existing native CPS3 flash engine,
  // with Am29F040B/Am29F016D geometry/IDs and asynchronous operations.
  TZXAM29F040 = class
  private
    FData: TBytes;
    FCommand: Integer;
    FID, FToggle, FSuspended, FDirty: Boolean;
    FProgramAddress: Cardinal;
    FProgramData: Byte;
    FEraseMask: Cardinal;
    FProgramLeft, FEraseLeft: Integer;
    procedure FinishProgram;
    procedure FinishErase;
    function GetActive: Boolean; inline;
  public
    constructor Create(const Data: TBytes);
    procedure PowerReset;
    procedure Advance(Osc24: Integer);
    function Read(Address: Cardinal): Byte;
    procedure Write(Address: Cardinal; Value: Byte);
    procedure SerializeState(State: TStateArchive);
    procedure LoadImage(const Data: TBytes);
    function Image: TBytes;
    procedure MarkDirty;
    property Dirty: Boolean read FDirty;
    property Active: Boolean read GetActive;
  end;

implementation

uses
  System.Classes;

constructor TZXAM29F040.Create(const Data: TBytes);
begin
  inherited Create;
  if (Length(Data) <> $80000) and (Length(Data) <> $200000) then
    raise EArgumentException.Create('AMD flash requires 512 KiB (040B) or 2 MiB (016D)');
  FData := Data;
  PowerReset;
end;

procedure TZXAM29F040.PowerReset;
begin
  FCommand := 0;
  FID := False;
  FToggle := False;
  FSuspended := False;
  FProgramLeft := 0;
  FEraseLeft := 0;
  FEraseMask := 0;
end;

procedure TZXAM29F040.FinishProgram;
begin
  var B := FData[FProgramAddress] and FProgramData;
  if B <> FData[FProgramAddress] then
  begin
    FDirty := True;
    FData[FProgramAddress] := B;
  end;
  FProgramLeft := 0;
end;

procedure TZXAM29F040.FinishErase;
begin
  for var Sector := 0 to Length(FData) div $10000 - 1 do
    if (FEraseMask and (Cardinal(1) shl Sector)) <> 0 then
      for var I := Sector * $10000 to (Sector + 1) * $10000 - 1 do
        if FData[I] <> $FF then
        begin
          FData[I] := $FF;
          FDirty := True;
        end;
  FEraseLeft := 0;
  FEraseMask := 0;
  FSuspended := False;
end;

function TZXAM29F040.GetActive: Boolean;
begin
  Result := (FProgramLeft > 0) or ((FEraseLeft > 0) and not FSuspended);
end;

procedure TZXAM29F040.Advance(Osc24: Integer);
begin
  if FProgramLeft > 0 then
  begin
    Dec(FProgramLeft, Osc24);
    if FProgramLeft <= 0 then
      FinishProgram;
  end;
  if (FEraseLeft > 0) and not FSuspended then
  begin
    Dec(FEraseLeft, Osc24);
    if FEraseLeft <= 0 then
      FinishErase;
  end;
end;

function TZXAM29F040.Read(Address: Cardinal): Byte;
begin
  Address := Address and Cardinal(Length(FData) - 1);
  Result := FData[Address];
  if FProgramLeft > 0 then
  begin
    FToggle := not FToggle;
    Result := (Result and $1F) or ((not FProgramData) and $80) or (Ord(FToggle) shl 6);
    Exit;
  end;
  if (FEraseLeft > 0) and ((FEraseMask and (Cardinal(1) shl (Address shr 16))) <> 0) then
  begin
    FToggle := not FToggle;
    if FSuspended then
      Result := (Result and $FB) or (Ord(FToggle) shl 2)
    else
      Result := (Result and $13) or 8 or (Ord(FToggle) shl 6);
    Exit;
  end;
  if FID then
    case Address and $FF of
      0:
        Result := 1;
      1:
        if Length(FData) = $80000 then
          Result := $A4
        else
          Result := $AD;
      2:
        Result := 0;
    else
      Result := $FF;
    end;
end;

procedure TZXAM29F040.Write(Address: Cardinal; Value: Byte);
begin
  Address := Address and Cardinal(Length(FData) - 1);
  if FProgramLeft > 0 then
    Exit;
  if (FEraseLeft > 0) and not FSuspended then
  begin
    if Value = $B0 then
      FSuspended := True;
    Exit;
  end;
  if FCommand = 3 then
  begin
    FCommand := 0;
    if FSuspended and ((FEraseMask and (Cardinal(1) shl (Address shr 16))) <> 0) then
      Exit;
    FProgramAddress := Address;
    FProgramData := Value;
    FProgramLeft := 168;
    FID := False;
    Exit;
  end;
  if Value = $F0 then
  begin
    FID := False;
    FCommand := 0;
    Exit;
  end;
  if FSuspended and (Value = $30) and (FCommand = 0) then
  begin
    FSuspended := False;
    Exit;
  end;
  case FCommand of
    0:
      if ((Address and $7FF) = $555) and (Value = $AA) then
        FCommand := 1;
    1:
      if ((Address and $7FF) = $2AA) and (Value = $55) then
        FCommand := 2
      else
        FCommand := 0;
    2:
      begin
        FCommand := 0;
        if (Address and $7FF) = $555 then
          case Value of
            $90:
              FID := True;
            $A0:
              FCommand := 3;
            $80:
              if not FSuspended then
                FCommand := 4;
          end;
      end;
    4:
      if ((Address and $7FF) = $555) and (Value = $AA) then
        FCommand := 5
      else
        FCommand := 0;
    5:
      if ((Address and $7FF) = $2AA) and (Value = $55) then
        FCommand := 6
      else
        FCommand := 0;
    6:
      begin
        FCommand := 0;
        FID := False;
        if Value = $30 then
          FEraseMask := Cardinal(1) shl (Address shr 16)
        else if (Value = $10) and ((Address and $7FF) = $555) then
          FEraseMask := Cardinal(UInt64($FFFFFFFF) shr (32 - Length(FData) div $10000));
        if FEraseMask <> 0 then
        begin
          FEraseLeft := 24000000;
          if FEraseMask = Cardinal(UInt64($FFFFFFFF) shr (32 - Length(FData) div $10000)) then
            FEraseLeft := 192000000;
        end;
      end;
  end;
end;

procedure TZXAM29F040.LoadImage(const Data: TBytes);
begin
  if Length(Data) <> Length(FData) then
    raise EReadError.Create('Invalid AMD flash image size');
  Move(Data[0], FData[0], Length(Data));
  PowerReset;
  FDirty := False;
end;

function TZXAM29F040.Image: TBytes;
begin
  Result := Copy(FData);
end;

procedure TZXAM29F040.MarkDirty;
begin
  FDirty := True;
end;

procedure TZXAM29F040.SerializeState(State: TStateArchive);
begin
  var Previous: TBytes;
  if State.Loading then
    Previous := Copy(FData);
  State.Field(FData[0], Length(FData));
  State.Field(FCommand, 4);
  State.Field(FID, SizeOf(FID));
  State.Field(FToggle, SizeOf(FToggle));
  State.Field(FSuspended, SizeOf(FSuspended));
  State.Field(FDirty, SizeOf(FDirty));
  State.Field(FProgramAddress, 4);
  State.Field(FProgramData, 1);
  State.Field(FEraseMask, 4);
  State.Field(FProgramLeft, 4);
  State.Field(FEraseLeft, 4);
  if (FCommand < 0) or (FCommand > 6) or (FProgramAddress >= Cardinal(Length(FData))) or
    (FProgramLeft < 0) or (FProgramLeft > 168) or (FEraseLeft < 0) or (FEraseLeft > 192000000) or
    ((FEraseLeft > 0) <> (FEraseMask <> 0)) or (FSuspended and (FEraseLeft = 0)) then
    raise EReadError.Create('Invalid AMD flash operation state');
  if State.Loading and not CompareMem(@Previous[0], @FData[0], Length(FData)) then
    FDirty := True;
end;

end.

