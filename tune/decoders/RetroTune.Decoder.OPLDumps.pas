unit RetroTune.Decoder.OPLDumps;

interface

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections, RetroTune.Decoder,
  RetroTune.Binary, PC.Sound.OPL, PC.Sound.OPL2, PC.Sound.OPL3;

type
  TOPLEvent = record
    Time: Int64;
    Port, Reg, Value: Byte;
  end;

  TOPLDumpDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FInfo: TTuneInfo;
    FEvents: TArray<TOPLEvent>;
    FChips: array[0..1] of TOPLSound;
    FHardware, FEvent: Integer;
    FPosition, FLength: Int64;
  public
    constructor Create(const Data: TBytes; IsDRO: Boolean);
    destructor Destroy; override;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

constructor TOPLDumpDecoder.Create(const Data: TBytes; IsDRO: Boolean);
var
  Events: TList<TOPLEvent>;
  Time: Int64;
  Rate, Port: Integer;

  procedure Delay(Ticks: Integer);
  begin
    Inc(Time, Ticks);
    if Time > Int64(Rate) * 86400 then
      raise EArgumentException.Create('OPL dump exceeds 24 hours');
  end;

  procedure WriteReg(Reg, Value: Byte; Bank: Integer);
  var
    E: TOPLEvent;
  begin
    if (Bank <> 0) and (FHardware = 0) then
      raise EArgumentException.Create('OPL dump uses an undeclared second chip');
    E.Time := Time * 44100 div Rate;
    E.Port := Bank;
    E.Reg := Reg;
    E.Value := Value;
    Events.Add(E);
  end;

begin
  inherited Create;
  RequireBytes(Data, 0, 4);
  Time := 0;
  Port := 0;
  FInfo.TrackCount := 1;
  FInfo.SampleRate := 44100;
  FInfo.Channels := 2;
  Events := TList<TOPLEvent>.Create;
  try
    if not IsDRO then
    begin
      Rate := 700;
      FHardware := 0;
      FInfo.FormatName := 'IMF';
      FInfo.Details := 'AdLib OPL2 / 700 Hz / IMF type 0 or 1';
      var Start := 0;
      var Count := Length(Data);
      // Type 1 has a nonzero little-endian byte length; type 0 begins with
      // a register/value pair. The two formats have no unique signature.
      var Declared := Integer(LE16(Data, 0));
      if (Declared > 0) and (Declared mod 4 = 0) and (Declared <= Length(Data) - 2) then
      begin
        Start := 2;
        Count := Declared;
        if Start + Count < Length(Data) then
          FInfo.Title := TextField(Data, Start + Count, Length(Data) - Start - Count);
      end;
      if (Count = 0) or (Count mod 4 <> 0) then
        raise EArgumentException.Create('Invalid IMF record length');
      RequireBytes(Data, Start, Count);
      for var P := 0 to Count div 4 - 1 do
      begin
        var Offset := Start + P * 4;
        WriteReg(Data[Offset], Data[Offset + 1], 0);
        Delay(LE16(Data, Offset + 2));
      end;
    end
    else
    begin
      Rate := 1000;
      RequireBytes(Data, 0, 24);
      if TEncoding.ASCII.GetString(Data, 0, 8) <> 'DBRAWOPL' then
        raise EArgumentException.Create('Invalid DRO signature');
      var Version: Integer;
      if (LE16(Data, 8) = 0) and (LE16(Data, 10) = 1) then
        Version := 1
      else if (LE16(Data, 8) = 2) and (LE16(Data, 10) = 0) then
        Version := 2
      else
        raise EArgumentException.Create('Unsupported DRO version (expected 1.0 or 2.0)');
      var P, Count: Integer;
      if Version = 1 then
      begin
        FHardware := Integer(LE32(Data, 20));
        if FHardware = 1 then
          FHardware := 2
        else if FHardware = 2 then
          FHardware := 1;
        P := 24;
        if LE32(Data, 16) > Cardinal(Length(Data) - P) then
          raise EArgumentException.Create('Truncated DRO v1 data');
        Count := Integer(LE32(Data, 16));
      end
      else
      begin
        RequireBytes(Data, 0, 26);
        FHardware := Data[20];
        if (Data[21] <> 0) or (Data[22] <> 0) then
          raise EArgumentException.Create('Unsupported DRO encoding/compression');
        if (Data[25] = 0) or (Data[25] > 128) or (Data[23] = Data[24]) then
          raise EArgumentException.Create('Invalid DRO code map');
        P := 26 + Data[25];
        RequireBytes(Data, 26, Data[25]);
        if LE32(Data, 12) > Cardinal((Length(Data) - P) div 2) then
          raise EArgumentException.Create('Truncated DRO v2 data');
        Count := Integer(LE32(Data, 12)) * 2;
      end;
      if (FHardware < 0) or (FHardware > 2) or (Count = 0) then
        raise EArgumentException.Create('Invalid DRO hardware/data size');
      var EndPos := P + Count;
      if EndPos <> Length(Data) then
        raise EArgumentException.Create('Unexpected DRO trailing data');
      var InitEnd := P;
      // Original DOSBox v1 captures start with an ascending register dump,
      // including unescaped writes to registers 01 and 04. Edited captures
      // can start with a proper escape instead, which must stay an escape.
      if (Version = 1) and (Data[P] = 1) then
      begin
        var Scan := P;
        var ScanPort := 0;
        var LastReg := -1;
        while Scan < EndPos do
        begin
          var C := Data[Scan];
          if C in [2, 3] then
          begin
            ScanPort := C - 2;
            Inc(Scan);
            Continue;
          end;
          var RegisterNumber := ScanPort * 256 + C;
          if (C = 0) or (Scan + 1 >= EndPos) or
            (RegisterNumber < LastReg) then
            Break;
          LastReg := RegisterNumber;
          Inc(Scan, 2);
        end;
        InitEnd := Scan;
      end;
      while P < EndPos do
      begin
        var Code := Data[P];
        Inc(P);
        if Version = 2 then
        begin
          RequireBytes(Data, P, 1);
          var Value := Data[P];
          Inc(P);
          if Code = Data[23] then
            Delay(Integer(Value) + 1)
          else if Code = Data[24] then
            Delay((Integer(Value) + 1) * 256)
          else
          begin
            if (Code and 127) >= Data[25] then
              raise EArgumentException.Create('Invalid DRO register code');
            WriteReg(Data[26 + (Code and 127)], Value, Code shr 7);
          end;
        end
        else
          case Code of
            0:
              begin
                RequireBytes(Data, P, 1);
                Delay(Integer(Data[P]) + 1);
                Inc(P);
              end;
            1:
              begin
                RequireBytes(Data, P, 1);
                var DirectWrite := P < InitEnd;
                if P + 1 < EndPos then
                  DirectWrite := DirectWrite or ((Data[P] in [0, $20]) and
                    ((Data[P + 1] = 8) or (Data[P + 1] >= $20)));
                if DirectWrite then
                begin
                  WriteReg(1, Data[P], Port);
                  Inc(P);
                end
                else
                begin
                  if P + 2 > EndPos then
                    raise EArgumentException.Create('Truncated DRO delay');
                  Delay(Integer(LE16(Data, P)) + 1);
                  Inc(P, 2);
                end;
              end;
            2, 3:
              Port := Code - 2;
          else
            begin
              if Code = 4 then
              begin
                RequireBytes(Data, P, 1);
                if (Data[P] < 8) and (P >= InitEnd) then
                begin
                  Code := Data[P];
                  Inc(P);
                end;
              end;
              RequireBytes(Data, P, 1);
              WriteReg(Code, Data[P], Port);
              Inc(P);
            end;
          end;
      end;
      // DOSBox v2 can mislabel OPL3 captures as dual OPL2. An explicit
      // new-mode enable in the second bank unambiguously identifies OPL3.
      if (Version = 2) and (FHardware = 1) then
        for var E in Events do
          if (E.Port = 1) and (E.Reg = 5) and (E.Value and 1 <> 0) then
            FHardware := 2;
      FInfo.FormatName := 'DRO';
      FInfo.Details := Format('DOSBox RAW OPL v%d / hardware %d', [Version, FHardware]);
    end;
    FEvents := Events.ToArray;
  finally
    Events.Free;
  end;
  FLength := Time * 44100 div Rate;
  FInfo.TrackDurations := [FLength / 44100];
  if FHardware = 2 then
    FChips[0] := TOPL3.Create
  else
    FChips[0] := TOPL2.Create;
  if FHardware = 1 then
    FChips[1] := TOPL2.Create;
  SelectTrack(0);
end;

destructor TOPLDumpDecoder.Destroy;
begin
  FChips[1].Free;
  FChips[0].Free;
  inherited;
end;

function TOPLDumpDecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

procedure TOPLDumpDecoder.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('OPL dump track');
  FEvent := 0;
  FPosition := 0;
  for var Chip in FChips do
    if Chip <> nil then
      Chip.Reset;
end;

function TOPLDumpDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 2);
  Result := 0;
  while (Result < Frames) and (FPosition < FLength) do
  begin
    while (FEvent < Length(FEvents)) and (FEvents[FEvent].Time <= FPosition) do
    begin
      var E := FEvents[FEvent];
      if FHardware = 2 then
        FChips[0].WriteRegister(Word(E.Reg) + Word(E.Port) * 256, E.Value)
      else
        FChips[E.Port].WriteRegister(E.Reg, E.Value);
      Inc(FEvent);
    end;
    var L, R, L2, R2: SmallInt;
    FChips[0].Sample(L, R);
    if FHardware = 1 then
    begin
      FChips[1].Sample(L2, R2);
      // DOSBox dual OPL2 routes the first chip left and the second right.
      R := R2;
    end;
    Samples[Result * 2] := L;
    Samples[Result * 2 + 1] := R;
    Inc(FPosition);
    Inc(Result);
  end;
end;

function OpenIMF(const Data: TBytes): ITuneDecoder;
begin
  Result := TOPLDumpDecoder.Create(Data, False);
end;

function OpenDRO(const Data: TBytes): ITuneDecoder;
begin
  Result := TOPLDumpDecoder.Create(Data, True);
end;

initialization
  TTuneDecoders.RegisterFormat('.imf', 'id Software AdLib IMF (700 Hz)', OpenIMF);
  TTuneDecoders.RegisterFormat('.dro', 'DOSBox RAW OPL', OpenDRO);

end.

