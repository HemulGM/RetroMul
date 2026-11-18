unit J2ME.SMAF;

interface

uses
  System.SysUtils, Audio.Types;

const
  SMAFContentType = 'application/vnd.smaf';
  SiemensSMAFContentType = 'application/x-smaf';

function OpenSMAF(const Data: TBytes): IAudioSource;

implementation

uses
  System.Classes, System.Generics.Collections, System.Generics.Defaults,
  System.Math, Audio.Decoder, Audio.Format.MIDI;

type
  TSMAFVolume = record
    Frame: Int64;
    Gain: Integer; // Squared volume in 127^2 units.
  end;

  TSMAFSource = class(TAudioMusicSource)
  private
    FData: TBytes;
    FRate, FWaveOffset, FWaveFrames: Integer;
    FFirstFrame, FTotalFrames, FPosition: Int64;
    FPredictor, FStep, FVolumeIndex, FGain: Integer;
    FVolumes: TArray<TSMAFVolume>;
    function DecodeSample(Code: Byte): SmallInt;
  public
    constructor Create(const Data: TBytes);
    function GetInfo: TAudioInfo; override;
    procedure SelectTrack(Index: Integer); override;
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer; override;
  end;

procedure InvalidSMAF;
begin
  raise EArgumentException.Create('Invalid SMAF data');
end;

procedure UnsupportedSMAF;
begin
  raise EArgumentException.Create('Unsupported SMAF track or event');
end;

function SMAFTag(const Data: TBytes; At: Integer; const Value: AnsiString): Boolean;
begin
  Result := CompareMem(@Data[At], @Value[1], Length(Value));
end;

function SMAFChunkEnd(const Data: TBytes; At, Limit: Integer): Integer;
begin
  if Limit - At < 8 then
    InvalidSMAF;
  var Size := (UInt32(Data[At + 4]) shl 24) or (UInt32(Data[At + 5]) shl 16) or
    (UInt32(Data[At + 6]) shl 8) or Data[At + 7];
  if Size > UInt32(Limit - At - 8) then
    InvalidSMAF;
  Result := At + 8 + Integer(Size);
end;

function SMAFEnd(const Data: TBytes): Integer;
begin
  if (Length(Data) < 10) or not SMAFTag(Data, 0, 'MMMD') then
    InvalidSMAF;
  Result := SMAFChunkEnd(Data, 0, Length(Data));
  if Result < 10 then
    InvalidSMAF;
  // PsmPlayer files can append the CRC residue after the declared container.
  if (Result <> Length(Data)) and
    ((Length(Data) - Result <> 2) or (Data[Result] <> $1D) or (Data[Result + 1] <> $0F)) then
    InvalidSMAF;
end;

function SMAFTimeBase(Code: Integer): Integer;
begin
  case Code of
    0, 1, 2:
      Exit(1 shl Code);
    3:
      Exit(5);
    $10, $11, $12, $13:
      Exit(10 * SMAFTimeBase(Code - $10));
  end;
  InvalidSMAF;
  Result := 0;
end;

function ReadSMAFByte(const Data: TBytes; var At: Integer; Limit: Integer): Byte;
begin
  if At >= Limit then
    InvalidSMAF;
  Result := Data[At];
  Inc(At);
end;

function ReadHandyPhoneTicks(const Data: TBytes; var At: Integer; Limit: Integer): Integer;
begin
  Result := ReadSMAFByte(Data, At, Limit);
  if Result >= 128 then
  begin
    var LowBits := ReadSMAFByte(Data, At, Limit);
    if LowBits >= 128 then
      InvalidSMAF;
    Result := 128 + ((Result and $7F) shl 7) + LowBits;
  end;
end;

procedure WriteMidiDelta(Stream: TStream; Value: Integer);
begin
  if Value >= 128 then
  begin
    var First := Value shr 7;
    var Bytes: array[0..2] of Byte;
    var Count := 0;
    repeat
      Bytes[Count] := $80 or (First and $7F);
      Inc(Count);
      First := First shr 7;
    until First = 0;
    for var I := Count - 1 downto 0 do
      Stream.WriteData(Bytes[I]);
  end;
  Stream.WriteData(Byte(Value and $7F));
end;

function OpenHandyPhoneScore(const Data: TBytes): IAudioSource;
type
  TEvent = record
    Time, Order: Integer;
    Status, First, Second: Byte;
  end;

  TChannel = record
    MIDIChannel, Bank, ProgramNumber, Octave, Volume, Pan, Expression, Pitch, Modulation: Integer;
    InstrumentChanged: Boolean;
  end;

  PChannel = ^TChannel;
const
  MaxEvents = 262144;
  DayMilliseconds = 86400000;
var
  Events: TList<TEvent>;
  EndTime, NextChannel, ScoreTracks: Integer;

  procedure Add(Time, Status, First, Second: Integer);
  begin
    if (Events.Count >= MaxEvents) or (Time > DayMilliseconds) then
      InvalidSMAF;
    var E: TEvent;
    E.Time := Time;
    E.Order := Events.Count;
    E.Status := Status;
    E.First := First;
    E.Second := Second;
    Events.Add(E);
    EndTime := Max(EndTime, Time);
  end;

  procedure ReadSequence(Start, Limit, DurationBase, GateBase: Integer);
  var
    Channels: array[0..3] of TChannel;
    Time: Integer;

    procedure Control(const C: TChannel; Number, Value: Integer);
    begin
      if C.MIDIChannel >= 0 then
        Add(Time, $B0 or C.MIDIChannel, Number, Value);
    end;

    procedure PitchBend(const C: TChannel);
    begin
      if C.MIDIChannel >= 0 then
        Add(Time, $E0 or C.MIDIChannel, 0, C.Pitch);
    end;

    procedure AssignChannel(var C: TChannel);
    begin
      if C.MIDIChannel >= 0 then
        Exit;
      if NextChannel = 9 then
        Inc(NextChannel);
      if NextChannel > 15 then
        UnsupportedSMAF;
      C.MIDIChannel := NextChannel;
      Inc(NextChannel);
      Control(C, 7, C.Volume);
      Control(C, 10, C.Pan);
      Control(C, 11, C.Expression);
      Control(C, 1, C.Modulation);
      PitchBend(C);
    end;

    procedure ReadControl(var At: Integer);
    begin
      var Command := ReadSMAFByte(Data, At, Limit);
      var C: PChannel := @Channels[Command shr 6];
      var Code := Command and $3F;
      var Value := Code and $0F;
      case Code shr 4 of
        0:
          begin
            if not InRange(Value, 1, 14) then
              InvalidSMAF;
            if Value = 1 then
              C.Expression := 0
            else
              C.Expression := (Value + 2) * 8 - 1;
            Control(C^, 11, C.Expression);
          end;
        1:
          begin
            if not InRange(Value, 1, 14) then
              InvalidSMAF;
            C.Pitch := Value * 8;
            PitchBend(C^);
          end;
        2:
          begin
            if not InRange(Value, 1, 14) then
              InvalidSMAF;
            C.Modulation := (Value - 1) * 8;
            if Value = 14 then
              C.Modulation := 127;
            Control(C^, 1, C.Modulation);
          end;
        3:
          begin
            var Parameter := ReadSMAFByte(Data, At, Limit);
            if (Value <> 1) and (Value <> 2) and (Parameter > 127) then
              InvalidSMAF;
            case Value of
              0:
                begin
                  C.ProgramNumber := Parameter;
                  C.InstrumentChanged := True;
                end;
              1:
                begin
                  C.Bank := Parameter;
                  C.InstrumentChanged := True;
                end;
              2:
                begin
                  C.Octave := Parameter and $7F;
                  if C.Octave > 4 then
                    InvalidSMAF;
                  if Parameter >= 128 then
                    C.Octave := -C.Octave;
                end;
              3:
                begin
                  C.Modulation := Parameter;
                  Control(C^, 1, Parameter);
                end;
              4:
                begin
                  C.Pitch := Parameter;
                  PitchBend(C^);
                end;
              7:
                begin
                  C.Volume := Parameter;
                  Control(C^, 7, Parameter);
                end;
              10:
                begin
                  C.Pan := Parameter;
                  Control(C^, 10, Parameter);
                end;
              11:
                begin
                  C.Expression := Parameter;
                  Control(C^, 11, Parameter);
                end;
            else
              UnsupportedSMAF;
            end;
          end;
      end;
    end;

  begin
    for var C := Low(Channels) to High(Channels) do
    begin
      Channels[C] := Default(TChannel);
      Channels[C].MIDIChannel := -1;
      Channels[C].Volume := 100;
      Channels[C].Pan := 64;
      Channels[C].Pitch := 64;
      Channels[C].Expression := 127;
      Channels[C].InstrumentChanged := True;
    end;
    var At := Start;
    Time := 0;
    while At < Limit do
    begin
      if (Limit - At = 4) and SMAFTag(Data, At, #0#0#0#0) then
        Break;
      Inc(Time, ReadHandyPhoneTicks(Data, At, Limit) * DurationBase);
      if Time > DayMilliseconds then
        InvalidSMAF;
      var Code := ReadSMAFByte(Data, At, Limit);
      case Code of
        0:
          ReadControl(At);
        $FF:
          case ReadSMAFByte(Data, At, Limit) of
            0:
              ;
            $F0:
              begin
                var Size := ReadSMAFByte(Data, At, Limit);
                if (Size < 1) or (Size > Limit - At) or (Data[At + Size - 1] <> $F7) then
                  InvalidSMAF;
                // Device-specific Yamaha FM parameters are outside the GM renderer.
                Inc(At, Size);
              end;
          else
            UnsupportedSMAF;
          end;
      else
        var Note := Code and $0F;
        if not InRange(Note, 1, 12) then
          InvalidSMAF;
        var Gate := ReadHandyPhoneTicks(Data, At, Limit) * GateBase;
        if Gate = 0 then
          Continue;
        var C: PChannel := @Channels[Code shr 6];
        var Channel, Velocity: Integer;
        if C.Bank >= 128 then
        begin
          // Handy Phone rhythm patches have GM percussion program numbers.
          Channel := 9;
          Note := C.ProgramNumber;
          Velocity := C.Volume * C.Expression div 127;
        end
        else
        begin
          Note := 36 + 12 * (((Code shr 4) and 3) + C.Octave) + Note;
          if not InRange(Note, 0, 127) then
            Continue;
          AssignChannel(C^);
          Channel := C.MIDIChannel;
          Velocity := 100;
          if C.InstrumentChanged then
          begin
            Control(C^, 0, C.Bank);
            Add(Time, $C0 or Channel, C.ProgramNumber, 0);
            C.InstrumentChanged := False;
          end;
        end;
        Add(Time, $90 or Channel, Note, Velocity);
        Add(Time + Gate, $80 or Channel, Note, 0);
      end;
    end;
    EndTime := Max(EndTime, Time);
  end;

  function EncodeMIDI: TBytes;
  const
    // Format 0, one track, 500 ticks/quarter at the default 500 ms tempo.
    Header: array[0..17] of Byte = ($4D, $54, $68, $64, 0, 0, 0, 6, 0, 0, 0, 1, 1, $F4, $4D, $54, $72, $6B);
    EndOfTrack: array[0..2] of Byte = ($FF, $2F, 0);
  begin
    var Stream := TBytesStream.Create;
    try
      Stream.WriteBuffer(Header[0], Length(Header));
      Stream.WriteData(Int32(0));
      var Previous := 0;
      Events.Sort(TComparer<TEvent>.Construct(
        function(const Left, Right: TEvent): Integer
        begin
          Result := Left.Time - Right.Time;
          if Result = 0 then
            Result := Left.Order - Right.Order;
        end));
      for var E in Events do
      begin
        WriteMidiDelta(Stream, E.Time - Previous);
        Stream.WriteData(E.Status);
        Stream.WriteData(E.First);
        if E.Status and $F0 <> $C0 then
          Stream.WriteData(E.Second);
        Previous := E.Time;
      end;
      WriteMidiDelta(Stream, EndTime - Previous);
      Stream.WriteBuffer(EndOfTrack[0], Length(EndOfTrack));
      var TrackLength := Cardinal(Stream.Size - 22);
      Stream.Position := 18;
      Stream.WriteData(Byte(TrackLength shr 24));
      Stream.WriteData(Byte(TrackLength shr 16));
      Stream.WriteData(Byte(TrackLength shr 8));
      Stream.WriteData(Byte(TrackLength));
      Result := Copy(Stream.Bytes, 0, Stream.Size);
    finally
      Stream.Free;
    end;
  end;

begin
  Events := TList<TEvent>.Create;
  try
    EndTime := 0;
    NextChannel := 0;
    ScoreTracks := 0;
    var Limit := SMAFEnd(Data) - 2;
    var At := 8;
    while At < Limit do
    begin
      var Next := SMAFChunkEnd(Data, At, Limit);
      if SMAFTag(Data, At, 'MTR') then
      begin
        Inc(ScoreTracks);
        if (ScoreTracks > 4) or (Next - At < 14) or (Data[At + 8] <> 0) or (Data[At + 9] <> 0) then
          UnsupportedSMAF;
        var DurationBase := SMAFTimeBase(Data[At + 10]);
        var GateBase := SMAFTimeBase(Data[At + 11]);
        var Child := At + 14;
        var HasSequence := False;
        while Child < Next do
        begin
          var ChildEnd := SMAFChunkEnd(Data, Child, Next);
          if SMAFTag(Data, Child, 'Mtsq') then
          begin
            if HasSequence then
              InvalidSMAF;
            HasSequence := True;
            ReadSequence(Child + 8, ChildEnd, DurationBase, GateBase);
          end
          else if not (SMAFTag(Data, Child, 'Mtsu') or SMAFTag(Data, Child, 'MspI') or
            SMAFTag(Data, Child, 'MsqI')) then
            UnsupportedSMAF;
          Child := ChildEnd;
        end;
        if not HasSequence then
          InvalidSMAF;
      end
      else if not (SMAFTag(Data, At, 'CNTI') or SMAFTag(Data, At, 'OPDA')) then
        UnsupportedSMAF;
      At := Next;
    end;
    if (ScoreTracks = 0) or (Events.Count = 0) then
      InvalidSMAF;
    Result := OpenMidi(EncodeMIDI);
  finally
    Events.Free;
  end;
end;

function OpenSMAF(const Data: TBytes): IAudioSource;
begin
  var Limit := SMAFEnd(Data) - 2;
  var At := 8;
  while At < Limit do
  begin
    var Next := SMAFChunkEnd(Data, At, Limit);
    if SMAFTag(Data, At, 'MTR') then
      Exit(OpenHandyPhoneScore(Data));
    At := Next;
  end;
  Result := TSMAFSource.Create(Data);
end;

constructor TSMAFSource.Create(const Data: TBytes);
const
  // Handy Phone Standard PCM track, Yamaha SMAF 3.05 section 4.5.
  Rates: array[0..4] of Integer = (4000, 8000, 11025, 22050, 44100);
var
  SequenceStart, SequenceEnd: Integer;
  WaveOffset, WaveBytes: array[1..62] of Integer;
  DurationBase, GateBase: Integer;
  TrackFound: Boolean;

  procedure ReadTrack(Start, Limit: Integer);
  begin
    if Limit - Start < 6 then
      InvalidSMAF;
    var RateIndex := Data[Start + 2] and $0F;
    if (Data[Start] <> 0) or (Data[Start + 1] <> 0) or
      ((Data[Start + 2] and $F0) <> $10) or (Data[Start + 3] <> 0) or (RateIndex > High(Rates)) then
      UnsupportedSMAF;
    FRate := Rates[RateIndex];
    DurationBase := SMAFTimeBase(Data[Start + 4]);
    GateBase := SMAFTimeBase(Data[Start + 5]);
    var At := Start + 6;
    while At < Limit do
    begin
      var Next := SMAFChunkEnd(Data, At, Limit);
      if SMAFTag(Data, At, 'Atsq') then
      begin
        if SequenceStart <> 0 then
          InvalidSMAF;
        SequenceStart := At + 8;
        SequenceEnd := Next;
      end
      else if SMAFTag(Data, At, 'Awa') then
      begin
        var ID := Data[At + 3];
        if (ID < Low(WaveOffset)) or (ID > High(WaveOffset)) then
          InvalidSMAF;
        if (WaveOffset[ID] <> 0) or (Next = At + 8) then
          InvalidSMAF;
        WaveOffset[ID] := At + 8;
        WaveBytes[ID] := Next - WaveOffset[ID];
      end
      else if not (SMAFTag(Data, At, 'AspI') or SMAFTag(Data, At, 'Atsu')) then
        UnsupportedSMAF;
      At := Next;
    end;
  end;

begin
  inherited Create;
  var FileEnd := SMAFEnd(Data);
  FillChar(WaveOffset, SizeOf(WaveOffset), 0);
  FillChar(WaveBytes, SizeOf(WaveBytes), 0);
  SequenceStart := 0;
  SequenceEnd := 0;
  DurationBase := 0;
  GateBase := 0;
  TrackFound := False;
  var At := 8;
  var Limit := FileEnd - 2; // Container CRC follows the track chunks.
  while At < Limit do
  begin
    var Next := SMAFChunkEnd(Data, At, Limit);
    if SMAFTag(Data, At, 'ATR') then
    begin
      if TrackFound then
        UnsupportedSMAF;
      TrackFound := True;
      ReadTrack(At + 8, Next);
    end
    else if not (SMAFTag(Data, At, 'CNTI') or SMAFTag(Data, At, 'OPDA')) then
      UnsupportedSMAF;
    At := Next;
  end;
  if not TrackFound or (SequenceStart = 0) then
    UnsupportedSMAF;
  At := SequenceStart;
  var MilliTime: Int64 := 0;
  var Volume := 127;
  var Volumes := TList<TSMAFVolume>.Create;
  try
    while At < SequenceEnd do
    begin
      if (SequenceEnd - At = 4) and SMAFTag(Data, At, #0#0#0#0) then
        Break;
      Inc(MilliTime, Int64(ReadHandyPhoneTicks(Data, At, SequenceEnd)) * DurationBase);
      if MilliTime > 86400000 then
        InvalidSMAF;
      var Event := ReadSMAFByte(Data, At, SequenceEnd);
      if Event = 0 then
      begin
        // A mono ATR has one audio channel. The standard volume command
        // changes gain on that channel at its own playback timestamp.
        var Control := ReadSMAFByte(Data, At, SequenceEnd);
        if Control <> $37 then
          UnsupportedSMAF;
        var NewVolume := ReadSMAFByte(Data, At, SequenceEnd);
        if NewVolume > 127 then
          InvalidSMAF;
        if NewVolume <> Volume then
        begin
          Volume := NewVolume;
          var Change: TSMAFVolume;
          Change.Frame := MilliTime * FRate div 1000;
          Change.Gain := Volume * Volume;
          Volumes.Add(Change);
        end;
        Continue;
      end;
      if Event = $FF then
      begin
        if ReadSMAFByte(Data, At, SequenceEnd) <> 0 then
          UnsupportedSMAF;
        Continue;
      end;
      var ID := Event and $3F;
      if (Event shr 6 <> 0) or (ID < Low(WaveOffset)) or (ID > High(WaveOffset)) or (FWaveOffset <> 0) then
        UnsupportedSMAF;
      if WaveOffset[ID] = 0 then
        InvalidSMAF;
      FWaveOffset := WaveOffset[ID];
      FFirstFrame := MilliTime * FRate div 1000;
      FWaveFrames := Min(WaveBytes[ID] * 2, Int64(ReadHandyPhoneTicks(Data, At, SequenceEnd)) * GateBase * FRate div 1000);
    end;
    FVolumes := Volumes.ToArray;
  finally
    Volumes.Free;
  end;
  if (FWaveOffset = 0) or (FWaveFrames = 0) then
    InvalidSMAF;
  FTotalFrames := Max(FFirstFrame + FWaveFrames, MilliTime * FRate div 1000);
  FData := Data;
  SelectTrack(0);
end;

function TSMAFSource.GetInfo: TAudioInfo;
begin
  Result := Default(TAudioInfo);
  Result.SampleRate := FRate;
  Result.Channels := 1;
  Result.TrackCount := 1;
  Result.TrackDurations := [FTotalFrames / FRate];
end;

procedure TSMAFSource.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('SMAF track index');
  FPosition := 0;
  FPredictor := 0;
  FStep := 127;
  FVolumeIndex := 0;
  FGain := 127 * 127;
end;

function TSMAFSource.DecodeSample(Code: Byte): SmallInt;
const
  // Yamaha ADPCM scale factors in Q8, truncated from the decimal ratios.
  StepScale: array[0..7] of Integer = (230, 230, 230, 230, 307, 409, 512, 614);
begin
  var Magnitude := Code and 7;
  var Delta := (2 * Magnitude + 1) * FStep div 8;
  if (Code and 8) <> 0 then
    Delta := -Delta;
  FPredictor := EnsureRange(FPredictor + Delta, -32768, 32767);
  FStep := EnsureRange(FStep * StepScale[Magnitude] div 256, 127, 24576);
  Result := SmallInt(FPredictor);
end;

function TSMAFSource.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 1);
  Result := Integer(Min(Int64(Frames), FTotalFrames - FPosition));
  for var I := 0 to Result - 1 do
  begin
    var Frame := FPosition + I;
    while (FVolumeIndex < Length(FVolumes)) and (FVolumes[FVolumeIndex].Frame <= Frame) do
    begin
      FGain := FVolumes[FVolumeIndex].Gain;
      Inc(FVolumeIndex);
    end;
    var WaveFrame := Frame - FFirstFrame;
    if (WaveFrame >= 0) and (WaveFrame < FWaveFrames) then
    begin
      var Code := FData[FWaveOffset + WaveFrame div 2];
      // SMAF stores the first mono sample in the low nibble.
      if Odd(WaveFrame) then
        Code := Code shr 4;
      Samples[I] := DecodeSample(Code) * FGain div (127 * 127);
    end
    else
      Samples[I] := 0;
  end;
  Inc(FPosition, Result);
end;

end.

