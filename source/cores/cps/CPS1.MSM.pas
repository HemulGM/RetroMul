unit CPS1.MSM;

interface

uses
  System.SysUtils, CPS1.Boards, CPS.Cartridge, CPS.MSMSound, Core.Snapshots;

type
  TCPSMSMConsole = class(TCPS1BoardConsole)
  private
    FMix: TCPSMSMSound;
    FSprites, FExtraRAM: TArray<Word>;
    FPending, FSF, FKnights: Boolean;
    FInit, FMachine: string;
    function SpriteIndex(Address: Cardinal): Integer;
    procedure Layers(Offset: Integer; Value: Word);
  protected
    procedure BeginAudio; override;
    procedure BeginScanline(Line: Integer); override;
    procedure AdvanceSound(Cycles: Integer); override;
    procedure FinishFrame; override;
    function GetSamples: TArray<SmallInt>; override;
    function ReadZ(Address: Word): Byte; override;
    procedure WriteZ(Address: Word; Value: Byte); override;
  public
    constructor Create(Cart: TCPSCartridge);
    destructor Destroy; override;
    procedure Reset; override;
    function ReadWord(Address: Cardinal): Word; override;
    procedure WriteWord(Address: Cardinal; Value: Word; HighByte: Boolean = True; LowByte: Boolean = True); override;
    procedure SerializeState(State: TStateArchive); override;
  end;

implementation

uses
  CPS1.Sound, HW.Z80, HW.M68k;

constructor TCPSMSMConsole.Create(Cart: TCPSCartridge);
begin
  inherited;
  FMachine := Cart.RomSet.Machine;
  FInit := Cart.RomSet.Init;
  FSF := FMachine.StartsWith('sf2');
  FKnights := FMachine = 'knightsb';
  FSound.Free;
  FSound := TCPS1Sound.Create(nil, 3750000);
  FMix := TCPSMSMSound.Create(1 + Ord(FKnights));
  FClock := 12000000;
  FZClock := 3750000;
  SetLength(FSprites, $2000);
  if (FInit = 'init_sf2mdt') or (FInit = 'init_sf2mdta') then
    SetLength(FExtraRAM, $8000);
  if FSF then
    Video.ConfigureBootleg($26, [$28, $2A, $2C, $2E], 0, 0, 0, $1000, $8000, False, 2)
  else
    Video.ConfigureBootleg($28, [$26, $24, $22, $20], 62, 60, 64, $1000, $8000, False, 0, 1);
  Video.BindBootlegSprites(FSprites);
  Reset;
end;

destructor TCPSMSMConsole.Destroy;
begin
  FMix.Free;
  inherited;
end;

procedure TCPSMSMConsole.Reset;
begin
  inherited;
  FPending := False;
  if FMix <> nil then
    FMix.Reset;
  if Length(FSprites) > 0 then
    FillChar(FSprites[0], Length(FSprites) * 2, 0);
  if Length(FExtraRAM) > 0 then
    FillChar(FExtraRAM[0], Length(FExtraRAM) * 2, 0);
end;

procedure TCPSMSMConsole.BeginAudio;
begin
  inherited;
  FMix.BeginFrame;
end;

procedure TCPSMSMConsole.BeginScanline(Line: Integer);
begin
  if Line = 240 then
    Clown68000Interrupt(FCPU, 2 + 2 * Ord(FSF));
end;

procedure TCPSMSMConsole.AdvanceSound(Cycles: Integer);
begin
  inherited;

  // OPM timers run, but its IRQ pin is disconnected on these boards.
  Z80Interrupt(FZ80, Ord(FPending));
  FMix.Advance(Cycles, FSound, FZ80);
end;

procedure TCPSMSMConsole.FinishFrame;
begin
  FSound.EndFrame;
  FMix.EndFrame;
  Video.Render;
end;

function TCPSMSMConsole.GetSamples: TArray<SmallInt>;
begin
  Result := FMix.Samples;
end;

function TCPSMSMConsole.ReadZ(Address: Word): Byte;
begin
  if Address < $8000 then
    Exit(FAudio[Address]);

  if Address < $C000 then
  begin
    var Mask := 15;
    if FSF then
      Mask := 7;
    var A := $10000 + (FBank and Mask) * $4000 + (Address and $3FFF);
    if A < Length(FAudio) then
      Exit(FAudio[A]);
    Exit($FF);
  end;

  if (Address >= $D000) and (Address < $D800) then
    Exit(FZRAM[Address and $7FF]);

  if (Address and $FC00) = $D800 then
    Exit(inherited ReadZ($F001));

  if (Address and $FC00) = $DC00 then
  begin
    FPending := False;
    Z80Interrupt(FZ80, 0);
    Exit(FCommand);
  end;

  Result := $FF;
end;

procedure TCPSMSMConsole.WriteZ(Address: Word; Value: Byte);
begin
  if (Address >= $D000) and (Address < $D800) then
    FZRAM[Address and $7FF] := Value;
  case Address and $FC00 of
    $D800:
      inherited WriteZ($F000 + (Address and 1), Value);
    $E000:
      begin
        FBank := Value;
        FMix.Bank(Value);
      end;
    $E400:
      FMix.Data(0, Value);
    $E800:
      FMix.Data(1, Value);
  end;
end;

function TCPSMSMConsole.SpriteIndex(Address: Cardinal): Integer;
begin
  Result := -1;
  if FSF then
  begin
    if (Address >= $700000) and (Address < $708000) then
      Result := (Address and $3FFF) div 2;
  end
  else if (Address >= $990000) and (Address < $994000) then
    Result := (Address - $990000) div 2;
end;

function TCPSMSMConsole.ReadWord(Address: Cardinal): Word;
begin
  Address := Address and $FFFFFE;
  var i := SpriteIndex(Address);
  if i >= 0 then
    Exit(FSprites[i]);

  if (Length(FExtraRAM) > 0) and (Address >= $FC0000) and (Address < $FD0000) then
    Exit(FExtraRAM[(Address - $FC0000) div 2]);

  if FSF then
  begin
    if (FMachine = 'sf2b') and (Address = $800140 + Cardinal(FCart.RomSet.Board.IDRegister)) then
      Exit(Word(FCart.RomSet.Board.IDValue));

    if Address = $70C000 then
      Exit(inherited ReadWord($800000));

    if Address = $70C008 then
      Exit(inherited ReadWord($800176));

    if (Address >= $70C018) and (Address < $70C020) then
    begin
      Result := inherited ReadWord(Address + $F4000) shr 8;
      Exit(Result or (Result shl 8));
    end;
  end
  else if Address = $800002 then
    Exit((Word(ExtraPad(FInput.Buttons4)) shl 8) or ExtraPad(FInput.Buttons3));

  Result := inherited;
end;

procedure TCPSMSMConsole.WriteWord(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean);

  procedure Merge(var Dest: Word);
  begin
    if HighByte then
      Dest := (Dest and $FF) or (Value and $FF00);
    if LowByte then
      Dest := (Dest and $FF00) or (Value and $FF);
  end;

begin
  Address := Address and $FFFFFE;
  var i := SpriteIndex(Address);
  if i >= 0 then
  begin
    Merge(FSprites[i]);
    Exit;
  end;

  if (Length(FExtraRAM) > 0) and (Address >= $FC0000) and (Address < $FD0000) then
  begin
    Merge(FExtraRAM[(Address - $FC0000) div 2]);
    Exit;
  end;

  if (not FSF and (Address = $800006)) or (FSF and (Address = $70C106)) then
  begin
    if (FSF and HighByte) or (not FSF and LowByte) then
    begin
      if FSF then
        FCommand := Byte(Value shr 8)
      else
        FCommand := Byte(Value and $FF);
      FPending := True;
      Z80Interrupt(FZ80, 1);
    end;
    Exit;
  end;

  if (not FSF and (Address >= $980000) and (Address < $980026)) then
  begin
    Layers((Address - $980000) div 2, Value);
    Exit;
  end;

  if FSF and (Address >= $708100) and (Address < $708200) then
  begin
    Layers((Address - $708100) div 2, Value);
    Exit;
  end;

  inherited;
end;

procedure TCPSMSMConsole.Layers(Offset: Integer; Value: Word);
const
  S: array[0..5] of Integer = (7, 6, 9, 8, 11, 10);
begin
  if FSF then
  begin
    if Offset = $26 then
    begin
      Video.B[$26 div 2] := Value;
      Exit;
    end;

    if FInit = 'init_sf2mdt' then
      case Offset of
        6:
          Video.A[10] := (Integer(Value) - 50) and $FFFF;
        7:
          Video.A[11] := Value;
        8:
          Video.A[8] := (Integer(Value) - 50) and $FFFF;
        9:
          Video.A[6] := (Integer(Value) - 54) and $FFFF;
        10:
          begin
            Video.A[9] := Value;
            Video.A[16] := Value;
          end;
        11:
          Video.A[7] := Value;
      end
    else
      case Offset of
        6:
          Video.A[6] := (Integer(Value) - 66) and $FFFF;
        7:
          Video.A[7] := Value;
        8:
          Video.A[10] := (Integer(Value) - 50) and $FFFF;
        9:
          begin
            Video.A[9] := Value;
            Video.A[16] := Value;
          end;
        10:
          Video.A[8] := (Integer(Value) - 50) and $FFFF;
        11:
          Video.A[11] := Value;
      end;
    Exit;
  end;

  if Offset <= 5 then
  begin
    Video.A[S[Offset]] := Value;
    if Offset = 2 then
      Video.A[16] := Value;
    Exit;
  end;

  case Offset of
    6:
      begin
        if FKnights then
          case Value of
            0, $1F, $FF, $7FF:
              Value := $12F2;
            $2000:
              Value := $06C0;
            $5800, $5F00:
              Value := $12C0;
            $80FF, $87FF, $D800:
              Value := $1380;
            $A000:
              Value := $24C0;
          end
        else
          Video.A[1] := $9000 + ((Value and $1F) shl 5);
        Video.B[$28 div 2] := Value;
      end;
    $10:
      Video.B[$24 div 2] := Value;
    $11:
      begin
        Video.B[$22 div 2] := Value;
        if not FKnights then
        begin
          Video.B[$22 div 2] := Value and $7FFF;
          if Value and $8000 <> 0 then
            Video.B[$20 div 2] := $7FFF
          else
            Video.B[$20 div 2] := $07FF;
        end;
      end;
    $12:
      if FKnights then
        Video.B[$20 div 2] := Value;
  end;
end;

procedure TCPSMSMConsole.SerializeState(State: TStateArchive);
begin
  inherited;
  FMix.SerializeState(State);
  State.Field(FPending, SizeOf(FPending));
  State.Field(FSprites[0], Length(FSprites) * 2);
  if Length(FExtraRAM) > 0 then
    State.Field(FExtraRAM[0], Length(FExtraRAM) * 2);
end;

end.

