unit RetroTune.Decoder.XGM;

interface

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections,
  System.Generics.Defaults, RetroTune.Decoder, RetroTune.Binary, MD.Sound,
  Core.AudioFilter;

type
  TXGMEvent = record
    Time: Int64;
    Order: Integer;
    Kind, Port, Reg, Value: Byte;
  end;

  TXGMTrack = record
    Events: TArray<TXGMEvent>;
    Frames: Int64;
    Title: string;
    Source: Integer;
  end;

  TXGMPCM = record
    Position, Remaining, Rate, Phase, Priority: Integer;
    Value: Integer;
    Active: Boolean;
  end;

  TXGMDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FInfo: TTuneInfo;
    FData: TBytes;
    FTracks: TArray<TXGMTrack>;
    FSampleStart, FSampleSize: array[0..248] of Integer;
    FPCM: array[0..3] of TXGMPCM;
    FFM: TFM;
    FPSG: TPSG;
    FTrack, FEvent, FRate, FPCMRate: Integer;
    FFMClock, FPSGClock: Integer;
    FPosition: Int64;
    FFMPhase, FPSGPhase: Double;
    FFMValue, FPSGValue: array[0..1] of Double;
    FFMFilter, FPSGFilter: array[0..1] of TPCMLowPass;
    FDC: array[0..1] of TPCMDCBlocker;
    FXGM2: Boolean;
    FPCMUsed: Boolean;
    procedure ParseTrack(const FMData, PSGData: TBytes; Track: Integer);
    procedure ApplyEvent(const E: TXGMEvent);
    procedure Sample(out Left, Right: SmallInt);
  public
    constructor Create(const Data: TBytes);
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

function UnpackXGM(const Data: TBytes): TBytes;
var
  Output: TList<Byte>;
begin
  Output := TList<Byte>.Create;
  try
    var P := 0;
    while P < Length(Data) do
    begin
      var Code := Data[P];
      Inc(P);
      var Literals := Code shr 5;
      var Match := Code and 31;
      var Distance: Integer;
      RequireBytes(Data, P, Literals);
      if Output.Count + Literals + Match > 16 * 1024 * 1024 then
        raise EArgumentException.Create('Expanded XGM2 exceeds 16 MiB');
      for var J := 0 to Literals - 1 do
        Output.Add(Data[P + J]);
      Inc(P, Literals);
      if Match > 1 then
      begin
        // SGDK's encoder stores the signed negative distance AFTER the
        // literals. The older text specification lists the opposite order.
        RequireBytes(Data, P, 1);
        Distance := 256 - Integer(Data[P]);
        Inc(P);
        if (Distance = 0) or (Distance > Output.Count) then
          raise EArgumentException.Create('Invalid XGM2 back reference');
        for var J := 1 to Match do
          Output.Add(Output[Output.Count - Distance]);
      end;
      // 00 marks an unpack-frame boundary; 01 a Z80 page boundary.
      // Neither terminates the entire packed music block.
    end;
    Result := Output.ToArray;
  finally
    Output.Free;
  end;
end;

constructor TXGMDecoder.Create(const Data: TBytes);
var
  Tracks: TList<TXGMTrack>;

  procedure ReadGD3(var P: Integer; Track: Integer);
  begin
    RequireBytes(FData, P, 12);
    if TEncoding.ASCII.GetString(FData, P, 4) <> 'Gd3 ' then
      raise EArgumentException.Create('Invalid XGM GD3 signature');
    var Size := LE32(FData, P + 8);
    if (Size > Cardinal(Length(FData) - P - 12)) or (Size and 1 <> 0) then
      raise EArgumentException.Create('Invalid XGM GD3 length');
    var At := P + 12;
    var EndPos := At + Integer(Size);
    for var Field := 0 to 10 do
    begin
      var Start := At;
      while (At + 2 <= EndPos) and (LE16(FData, At) <> 0) do
        Inc(At, 2);
      if At + 2 > EndPos then
        raise EArgumentException.Create('Truncated XGM GD3 text');
      var Value := TEncoding.Unicode.GetString(FData, Start, At - Start);
      if Field = 0 then
        FTracks[Track].Title := Value;
      if (Track = 0) and (Field = 6) then
        FInfo.Artist := Value;
      Inc(At, 2);
    end;
    Inc(P, 12 + Integer(Size));
  end;

  procedure ReadXD3(P, Track: Integer);
  begin
    var Size := LE32(FData, P);
    Inc(P, 4);
    if Size > Cardinal(Length(FData) - P) then
      raise EArgumentException.Create('Invalid XGM2 XD3 size');
    var EndPos := P + Integer(Size);
    for var Field := 0 to 5 do
    begin
      var Start := P;
      while (P < EndPos) and (FData[P] <> 0) do
        Inc(P);
      if P = EndPos then
        raise EArgumentException.Create('Truncated XGM2 XD3 text');
      var Value := TEncoding.UTF8.GetString(FData, Start, P - Start);
      if Field = 0 then
        FTracks[Track].Title := Value;
      if (Track = 0) and (Field = 2) then
        FInfo.Artist := Value;
      Inc(P);
    end;
    if P + 8 > EndPos then
      raise EArgumentException.Create('Truncated XGM2 XD3 duration');
  end;

begin
  inherited Create;
  FData := Copy(Data);
  RequireBytes(FData, 0, 4);
  var Magic := TEncoding.ASCII.GetString(FData, 0, 4);
  if (Magic <> 'XGM ') and (Magic <> 'XGM2') then
  begin
    // Compiled XGM2 omits the four-byte signature, keeping version/flags.
    if FData[0] <> $10 then
      raise EArgumentException.Create('Invalid XGM signature');
    FData := TBytes.Create(Ord('X'), Ord('G'), Ord('M'), Ord('2')) + FData;
    Magic := 'XGM2';
  end;
  FXGM2 := Magic = 'XGM2';
  RequireBytes(FData, 0, $104);
  FRate := 60;
  FPCMRate := 14000;
  FInfo.FormatName := 'XGM';
  FInfo.SampleRate := 44100;
  FInfo.Channels := 2;
  if FXGM2 then
  begin
    if (FData[4] <> $10) or (FData[5] and $F0 <> 0) then
      raise EArgumentException.Create('Unsupported XGM2 version/flags');
    FInfo.FormatName := 'XGM2';
    FPCMRate := 13300;
    var Flags := FData[5];
    if Flags and 1 <> 0 then
      FRate := 50;
    var Multi := Flags and 2 <> 0;
    var HeaderSize := $104;
    var SampleCount := 123;
    if Multi then
    begin
      HeaderSize := $404;
      SampleCount := 248;
    end;
    RequireBytes(FData, 0, HeaderSize);
    var SLen := Integer(LE16(FData, 6)) * 256;
    var FLen := Integer(LE16(FData, 8)) * 256;
    var PLen := Integer(LE16(FData, 10)) * 256;
    RequireBytes(FData, HeaderSize, SLen + FLen + PLen);
    for var I := 1 to SampleCount do
    begin
      var A := Integer(LE16(FData, 12 + (I - 1) * 2));
      if A = $FFFF then
        Continue;
      var Next := Integer(LE16(FData, 12 + I * 2));
      // The last address is a dummy end marker, including address zero
      // for an empty sample bank; it is followed by unused $FFFF slots.
      if (A * 256 = SLen) and (Next = $FFFF) then
        Continue;
      if (Next = $FFFF) or (Next < A) or (Next * 256 > SLen) then
        raise EArgumentException.Create('Invalid XGM2 sample bounds');
      FSampleStart[I] := HeaderSize + A * 256;
      FSampleSize[I] := (Next - A) * 256;
    end;
    var Count := 1;
    if Multi then
      Count := 128;
    Tracks := TList<TXGMTrack>.Create;
    try
      for var I := 0 to Count - 1 do
      begin
        var FA := 0;
        var PA := 0;
        var FE := FLen;
        var PE := PLen;
        if Multi then
        begin
          FA := LE16(FData, $204 + I * 2);
          PA := LE16(FData, $304 + I * 2);
          if (FA = $FFFF) and (PA = $FFFF) then
            Continue;
          if (FA = $FFFF) or (PA = $FFFF) then
            raise EArgumentException.Create('Incomplete XGM2 track pair');
          FA := FA * 256;
          PA := PA * 256;
          for var J := I + 1 to 127 do
          begin
            var A := Integer(LE16(FData, $204 + J * 2));
            if (A <> $FFFF) and (A * 256 > FA) then
              FE := Min(FE, A * 256);
            A := Integer(LE16(FData, $304 + J * 2));
            if (A <> $FFFF) and (A * 256 > PA) then
              PE := Min(PE, A * 256);
          end;
        end;
        if (FA >= FE) or (PA >= PE) then
          raise EArgumentException.Create('Invalid XGM2 track bounds');
        var FMData := Copy(FData, HeaderSize + SLen + FA, FE - FA);
        var PSGData := Copy(FData, HeaderSize + SLen + FLen + PA, PE - PA);
        if Flags and 8 <> 0 then
        begin
          FMData := UnpackXGM(FMData);
          PSGData := UnpackXGM(PSGData);
        end;
        SetLength(FTracks, 1);
        ParseTrack(FMData, PSGData, 0);
        FTracks[0].Source := I;
        Tracks.Add(FTracks[0]);
      end;
      FTracks := Tracks.ToArray;
    finally
      Tracks.Free;
    end;
    if Flags and 4 <> 0 then
    begin
      var TagBase := HeaderSize + SLen + FLen + PLen;
      if Multi then
        RequireBytes(FData, TagBase, 256);
      for var I := 0 to High(FTracks) do
      begin
        var P := TagBase;
        if Multi then
        begin
          var Offset := LE16(FData, TagBase + FTracks[I].Source * 2);
          if Offset = $FFFF then
            Continue;
          P := TagBase + 256 + Offset;
        end;
        if Flags and 8 <> 0 then
          ReadXD3(P, I)
        else
          ReadGD3(P, I);
      end;
    end;
  end
  else
  begin
    if (FData[$102] <> 1) or (FData[$103] and $F8 <> 0) then
      raise EArgumentException.Create('Unsupported XGM version/flags');
    var Flags := FData[$103];
    if Flags and 1 <> 0 then
      FRate := 50;
    var SLen := Integer(LE16(FData, $100)) * 256;
    RequireBytes(FData, $104, SLen);
    for var I := 1 to 63 do
    begin
      var A := Integer(LE16(FData, 4 + (I - 1) * 4));
      if A = $FFFF then
        Continue;
      var Size := Integer(LE16(FData, 6 + (I - 1) * 4)) * 256;
      if (A * 256 > SLen) or (Size > SLen - A * 256) then
        raise EArgumentException.Create('Invalid XGM sample bounds');
      FSampleStart[I] := $104 + A * 256;
      FSampleSize[I] := Size;
    end;
    var P := $104 + SLen;
    repeat
      var Size := LE32(FData, P);
      Inc(P, 4);
      if (Size = 0) or (Size > Cardinal(Length(FData) - P)) then
        raise EArgumentException.Create('Invalid XGM music length');
      var Track := Length(FTracks);
      if Track >= 128 then
        raise EArgumentException.Create('Too many XGM tracks');
      SetLength(FTracks, Track + 1);
      ParseTrack(Copy(FData, P, Integer(Size)), nil, Track);
      Inc(P, Integer(Size));
      if Flags and 2 <> 0 then
        ReadGD3(P, Track);
      if Flags and 4 = 0 then
        Break;
    until P = Length(FData);
    if P <> Length(FData) then
      raise EArgumentException.Create('Unexpected XGM trailing data');
  end;
  if Length(FTracks) = 0 then
    raise EArgumentException.Create('XGM has no tracks');
  FInfo.TrackCount := Length(FTracks);
  SetLength(FInfo.TrackNames, FInfo.TrackCount);
  SetLength(FInfo.TrackDurations, FInfo.TrackCount);
  for var I := 0 to High(FTracks) do
  begin
    FInfo.TrackDurations[I] := FTracks[I].Frames / 44100;
    FInfo.TrackNames[I] := FTracks[I].Title;
  end;
  FInfo.Title := FTracks[0].Title;
  FFMClock := 7670454;
  FPSGClock := 3579545;
  if FRate = 50 then
  begin
    FFMClock := 7600489;
    FPSGClock := 3546895;
  end;
  FInfo.Details := Format('Mega Drive / YM2612 + SN76489 / %d Hz / PCM %d Hz', [FRate, FPCMRate]);
  SelectTrack(0);
end;

procedure TXGMDecoder.ParseTrack(const FMData, PSGData: TBytes; Track: Integer);
var
  Events: TList<TXGMEvent>;
  Frame: Int64;
  Registers: array[0..1, 0..255] of Byte;
  Tones, Volumes: array[0..3] of Integer;

  procedure Wait(Count: Integer);
  begin
    Inc(Frame, Count);
    if Frame > 90000 then
      raise EArgumentException.Create('XGM exceeds 90,000 frames');
  end;

  procedure Emit(Kind, Port, Reg, Value: Integer);
  var
    E: TXGMEvent;
  begin
    if Events.Count >= 2000000 then
      raise EArgumentException.Create('Too many XGM commands');
    E.Time := Frame * 44100 div FRate;
    E.Order := Events.Count;
    E.Kind := Kind;
    E.Port := Port;
    E.Reg := Reg;
    E.Value := Value;
    Events.Add(E);
  end;

  procedure FM(Port, Reg, Value: Integer);
  begin
    Registers[Port, Reg] := Value and 255;
    Emit(0, Port, Reg, Value and 255);
  end;

  procedure PSG(Value: Integer);
  begin
    Emit(1, 0, 0, Value and 255);
  end;

  procedure Tone(Channel, Value: Integer);
  begin
    if Channel = 3 then
    begin
      Tones[Channel] := Value and 7;
      PSG($E0 or Tones[Channel]);
    end
    else
    begin
      Tones[Channel] := Value and $3FF;
      PSG($80 or (Channel shl 5) or (Value and 15));
      PSG((Value shr 4) and 63);
    end;
  end;

  procedure Volume(Channel, Value: Integer);
  begin
    Volumes[Channel] := Value and 15;
    PSG($90 or (Channel shl 5) or Volumes[Channel]);
  end;

  function ReadByte(const Stream: TBytes; var P: Integer): Integer;
  begin
    RequireBytes(Stream, P, 1);
    Result := Stream[P];
    Inc(P);
  end;

  procedure EndStream(const Stream: TBytes; var P: Integer);
  begin
    RequireBytes(Stream, P, 3);
    var Loop := Integer(Stream[P]) or (Integer(Stream[P + 1]) shl 8) or (Integer(Stream[P + 2]) shl 16);
    if (Loop <> $FFFFFF) and (Loop >= Length(Stream)) then
      raise EArgumentException.Create('Invalid XGM loop target');
    Inc(P, 3);
  end;

begin
  FillChar(Registers, SizeOf(Registers), 0);
  FillChar(Tones, SizeOf(Tones), 0);
  for var I := 0 to 3 do
    Volumes[I] := 15;
  Frame := 0;
  Events := TList<TXGMEvent>.Create;
  try
    var P := 0;
    var Ended := False;
    var SplitFrames := 0;
    while not Ended do
    begin
      var Code := ReadByte(FMData, P);
      var Low := Code and 15;
      var Group := Code shr 4;
      if not FXGM2 then
      begin
        case Group of
          0:
            if Code = 0 then
              Wait(1)
            else
              raise EArgumentException.Create('Invalid XGM wait');
          1:
            for var J := 0 to Low do
              PSG(ReadByte(FMData, P));
          2, 3:
            for var J := 0 to Low do
            begin
              var Reg := ReadByte(FMData, P);
              FM(Group - 2, Reg, ReadByte(FMData, P));
            end;
          4:
            for var J := 0 to Low do
              FM(0, $28, ReadByte(FMData, P));
          5:
            Emit(2, Low and 3, Low and 12, ReadByte(FMData, P));
          7:
            begin
              if Code = $7E then
                EndStream(FMData, P)
              else if Code <> $7F then
                raise EArgumentException.Create('Invalid XGM end command');
              Ended := True;
            end;
        else
          raise EArgumentException.Create('Invalid XGM command');
        end;
        Continue;
      end;
      case Group of
        0:
          begin
            var Count := Low + 1;
            if Low = 15 then
              Count := ReadByte(FMData, P) + 16;
            Wait(Max(0, Count - SplitFrames));
            SplitFrames := 0;
          end;
        1:
          begin
            if Low and 3 = 3 then
              raise EArgumentException.Create('Invalid XGM2 PCM channel');
            Emit(2, Low and 3, Low and 12, ReadByte(FMData, P));
          end;
        2:
          begin
            var Channel := Low and 3;
            var Port := (Low shr 2) and 1;
            if Channel = 3 then
              raise EArgumentException.Create('Invalid XGM2 FM channel');
            for var J := 0 to 27 do
              FM(Port, $30 + (J div 4) * 16 + (J mod 4) * 4 + Channel, ReadByte(FMData, P));
            FM(Port, $B0 + Channel, ReadByte(FMData, P));
            FM(Port, $B4 + Channel, ReadByte(FMData, P));
          end;
        3, 8, 10, 11:
          begin
            var Port := (Low shr 2) and 1;
            var Channel := Low and 3;
            var HighReg := $A4 + Channel;
            if Low and 8 <> 0 then
              HighReg := $AC + Channel;
            if (Channel = 3) and (Low and 8 = 0) then
              raise EArgumentException.Create('Invalid XGM2 frequency channel');
            if (Low and 8 <> 0) and (Channel = 3) then
              HighReg := $A6;
            var Value: Integer;
            if Group in [3, 8] then
            begin
              Value := ReadByte(FMData, P) * 256;
              Value := Value + ReadByte(FMData, P);
              if Value and $4000 <> 0 then
                FM(0, $28, (Port shl 2) or Channel);
            end
            else
            begin
              var Delta := ReadByte(FMData, P);
              var Sign := 1;
              if Delta and 1 <> 0 then
                Sign := -1;
              Value := ((Integer(Registers[Port, HighReg]) shl 8) or Registers[Port, HighReg - 4]) + Sign * ((Delta shr 1) + 1);
            end;
            FM(Port, HighReg, (Value shr 8) and 63);
            FM(Port, HighReg - 4, Value and 255);
            if (Group in [3, 8]) and (Value and $8000 <> 0) then
              FM(0, $28, $F0 or (Port shl 2) or Channel);
            if Group in [8, 11] then
            begin
              Wait(Max(0, 1 - SplitFrames));
              SplitFrames := 0;
            end;
          end;
        4, 5:
          begin
            if Low and 3 = 3 then
              raise EArgumentException.Create('Invalid XGM2 key channel');
            var Key := Low and 7;
            if Group = 4 then
            begin
              if Low and 8 <> 0 then
                Key := Key or $F0;
              FM(0, $28, Key);
            end
            else if Low and 8 = 0 then
            begin
              FM(0, $28, Key);
              FM(0, $28, Key or $F0);
            end
            else
            begin
              FM(0, $28, Key or $F0);
              FM(0, $28, Key);
            end;
          end;
        6, 7:
          begin
            if Low and 3 = 3 then
              raise EArgumentException.Create('Invalid XGM2 pan channel');
            var Port := Group - 6;
            var Reg := $B4 + (Low and 3);
            FM(Port, Reg, (Registers[Port, Reg] and 63) or ((Low and 12) shl 4));
          end;
        9, 12, 13:
          begin
            if Low and 3 = 3 then
              raise EArgumentException.Create('Invalid XGM2 TL channel');
            var Value := ReadByte(FMData, P);
            var Port := Value and 1;
            var Reg := $40 + (Low shr 2) * 4 + (Low and 3);
            if Group = 9 then
              Value := Value shr 1
            else
            begin
              var Sign := 1;
              if Value and 2 <> 0 then
                Sign := -1;
              Value := Integer(Registers[Port, Reg]) + Sign * ((Value shr 2) + 1);
            end;
            FM(Port, Reg, Value and 127);
            if Group = 13 then
            begin
              Wait(Max(0, 1 - SplitFrames));
              SplitFrames := 0;
            end;
          end;
        14:
          for var J := 0 to Low and 7 do
          begin
            var Reg := ReadByte(FMData, P);
            FM(Low shr 3, Reg, ReadByte(FMData, P));
          end;
        15:
          case Code of
            $F0:
              begin
                Inc(SplitFrames);
                Wait(1);
              end;
            $F8:
              FM(0, $28, ReadByte(FMData, P));
            $F9:
              FM(0, $22, ReadByte(FMData, P));
            $FA:
              FM(0, $27, Registers[0, $27] or $40);
            $FB:
              FM(0, $27, Registers[0, $27] and $BF);
            $FC:
              FM(0, $2B, $80);
            $FD:
              FM(0, $2B, 0);
            $FF:
              begin
                EndStream(FMData, P);
                Ended := True;
              end;
          else
            raise EArgumentException.Create('Reserved XGM2 FM command');
          end;
      end;
    end;
    var FMFrames := Frame;
    if FXGM2 then
    begin
      Frame := 0;
      P := 0;
      Ended := False;
      while not Ended do
      begin
        var Code := ReadByte(PSGData, P);
        var Low := Code and 15;
        var Group := Code shr 4;
        case Group of
          0:
            if Low = 15 then
            begin
              EndStream(PSGData, P);
              Ended := True;
            end
            else if Low = 14 then
              Wait(ReadByte(PSGData, P) + 15)
            else
              Wait(Low + 1);
          1:
            begin
              var Value := ReadByte(PSGData, P);
              if (Value and $90 <> $80) then
                raise EArgumentException.Create('Invalid XGM2 PSG low write');
              var Channel := (Value shr 5) and 3;
              Tones[Channel] := (Tones[Channel] and $3F0) or (Value and 15);
              PSG(Value);
              if Low and 1 <> 0 then
                Wait(1);
            end;
          2, 3:
            begin
              var Value := ReadByte(PSGData, P);
              Tone(Low shr 2, ((Low and 3) shl 8) or Value);
              if Group = 3 then
                Wait(1);
            end;
          4, 5, 6, 7:
            begin
              var Channel := Group - 4;
              var Sign := 1;
              if Low and 4 <> 0 then
                Sign := -1;
              Tone(Channel, Tones[Channel] + Sign * ((Low and 3) + 1));
              if Low and 8 <> 0 then
                Wait(1);
            end;
          8, 9, 10, 11:
            Volume(Group - 8, Low);
          12, 13, 14, 15:
            begin
              var Channel := Group - 12;
              var Sign := 1;
              if Low and 4 <> 0 then
                Sign := -1;
              Volume(Channel, Volumes[Channel] + Sign * ((Low and 3) + 1));
              if Low and 8 <> 0 then
                Wait(1);
            end;
        end;
      end;
    end;
    // Stable timestamp merge retains the order of register writes within
    // each stream; FM precedes PSG for simultaneous independent events.
    Events.Sort(TComparer<TXGMEvent>.Construct(
      function(const A, B: TXGMEvent): Integer
      begin
        if A.Time < B.Time then
          Exit(-1);
        if A.Time > B.Time then
          Exit(1);
        Result := A.Order - B.Order;
      end));
    FTracks[Track].Events := Events.ToArray;
    FTracks[Track].Frames := Max(Frame, FMFrames) * 44100 div FRate;
    for var E in Events do
      if (E.Kind = 2) and ((E.Value > 248) or ((E.Value <> 0) and (FSampleSize[E.Value] = 0))) then
        raise EArgumentException.Create('Invalid XGM PCM sample id');
  finally
    Events.Free;
  end;
end;

procedure TXGMDecoder.ApplyEvent(const E: TXGMEvent);
begin
  case E.Kind of
    0:
      begin
        FMDoAddress(FFM, E.Port, E.Reg);
        FMDoData(FFM, E.Value);
      end;
    1:
      PSGDoCommand(FPSG, E.Value);
    2:
      begin
        FPCMUsed := True;
        var Channel := Integer(E.Port);
        var Priority := Integer(E.Reg);
        if FXGM2 then
          Priority := E.Reg and 8;
        if FPCM[Channel].Active and (Priority < FPCM[Channel].Priority) then
          Exit;
        FPCM[Channel] := Default(TXGMPCM);
        if E.Value = 0 then
          Exit;
        FPCM[Channel].Position := FSampleStart[E.Value];
        FPCM[Channel].Remaining := FSampleSize[E.Value];
        FPCM[Channel].Active := True;
        FPCM[Channel].Priority := Priority;
        FPCM[Channel].Rate := FPCMRate;
        if FXGM2 and (E.Reg and 4 <> 0) then
          FPCM[Channel].Rate := FPCMRate div 2;
        FPCM[Channel].Phase := 44100;
      end;
  end;
end;

procedure TXGMDecoder.SelectTrack(Index: Integer);
begin
  if (Index < 0) or (Index >= Length(FTracks)) then
    raise EArgumentOutOfRangeException.Create('XGM track');
  FTrack := Index;
  FEvent := 0;
  FPosition := 0;
  FPCMUsed := False;
  FFMPhase := 0;
  FPSGPhase := 0;
  FillChar(FPCM, SizeOf(FPCM), 0);
  FillChar(FFMValue, SizeOf(FFMValue), 0);
  FillChar(FPSGValue, SizeOf(FPSGValue), 0);
  FFM := Default(TFM);
  FPSG := Default(TPSG);
  FMInitialise(FFM);
  PSGInitialise(FPSG);
  for var J := 0 to 1 do
  begin
    FFMFilter[J].Configure(FFMClock / 144.0, 14000);
    FPSGFilter[J].Configure(FPSGClock / 16.0, 14000);
    FFMFilter[J].Reset;
    FPSGFilter[J].Reset;
    FDC[J].Configure(44100, 20);
    FDC[J].Reset;
  end;
end;

procedure TXGMDecoder.Sample(out Left, Right: SmallInt);
begin
  var Mix := 0;
  for var C := 0 to 3 do
  begin
    if FPCM[C].Active then
    begin
      if FPCM[C].Phase >= 44100 then
      begin
        Dec(FPCM[C].Phase, 44100);
        if FPCM[C].Remaining = 0 then
          FPCM[C].Active := False
        else
        begin
          FPCM[C].Value := Integer(FData[FPCM[C].Position]);
          if FPCM[C].Value >= 128 then
            Dec(FPCM[C].Value, 256);
          Inc(FPCM[C].Position);
          Dec(FPCM[C].Remaining);
        end;
      end;
      if FPCM[C].Active then
        Inc(Mix, FPCM[C].Value);
      Inc(FPCM[C].Phase, FPCM[C].Rate);
    end;
  end;
  if FPCMUsed then
  begin
    FMDoAddress(FFM, 0, $2A);
    FMDoData(FFM, EnsureRange(Mix, -128, 127) + 128);
  end;
  FPSGPhase := FPSGPhase + FPSGClock / (16.0 * 44100);
  while FPSGPhase >= 1 do
  begin
    FPSGPhase := FPSGPhase - 1;
    var PCM: array[0..0] of SmallInt;
    PCM[0] := 0;
    PSGUpdate(FPSG, PCM);
    FPSGValue[0] := FPSGFilter[0].Process(PCM[0] div 8);
    FPSGValue[1] := FPSGValue[0];
  end;
  FFMPhase := FFMPhase + FFMClock / (144.0 * 44100);
  while FFMPhase >= 1 do
  begin
    FFMPhase := FFMPhase - 1;
    var PCM: array[0..1] of SmallInt;
    PCM[0] := 0;
    PCM[1] := 0;
    FMOutputSamples(FFM, PCM);
    for var J := 0 to 1 do
      FFMValue[J] := FFMFilter[J].Process(PCM[J]);
  end;
  Left := EnsureRange(Round(FDC[0].Process(FFMValue[0] + FPSGValue[0])), -32768, 32767);
  Right := EnsureRange(Round(FDC[1].Process(FFMValue[1] + FPSGValue[1])), -32768, 32767);
end;

function TXGMDecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

function TXGMDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 2);
  Result := 0;
  while (Result < Frames) and (FPosition < FTracks[FTrack].Frames) do
  begin
    while (FEvent < Length(FTracks[FTrack].Events)) and (FTracks[FTrack].Events[FEvent].Time <= FPosition) do
    begin
      ApplyEvent(FTracks[FTrack].Events[FEvent]);
      Inc(FEvent);
    end;
    Sample(Samples[Result * 2], Samples[Result * 2 + 1]);
    Inc(Result);
    Inc(FPosition);
  end;
end;

function OpenXGM(const Data: TBytes): ITuneDecoder;
begin
  Result := TXGMDecoder.Create(Data);
end;

initialization
  TTuneDecoders.RegisterFormat('.xgm', 'Mega Drive XGM / XGM2', OpenXGM);
  TTuneDecoders.RegisterFormat('.xgm2', 'Mega Drive XGM2', OpenXGM);
  TTuneDecoders.RegisterFormat('.xgc', 'Compiled Mega Drive XGM2', OpenXGM);

end.

