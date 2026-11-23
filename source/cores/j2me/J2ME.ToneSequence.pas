unit J2ME.ToneSequence;

interface

uses
  System.SysUtils, Audio.Types;

const
  J2METoneContentType = 'audio/x-tone-seq';
  J2METoneRate = 44100;
  J2METoneMaxBytes = 1024 * 1024;
  J2METoneSilence = -1;
  J2METoneVersion = -2;
  J2METoneTempo = -3;
  J2METoneResolution = -4;
  J2METoneBlockStart = -5;
  J2METoneBlockEnd = -6;
  J2METonePlayBlock = -7;
  J2METoneVolume = -8;
  J2METoneRepeat = -9;

function OpenJ2METoneSequence(const Data: TBytes; out Frames: Int64): IAudioSource;

implementation

uses
  System.Math, System.Generics.Collections, Audio.Decoder;

const
  MaxCommands = 1024 * 1024;
  MaxNotes = 256 * 1024;
  MaxFrames = Int64(J2METoneRate) * 86400;
  FramesPerMinute = Int64(J2METoneRate) * 60;

type
  TToneNote = record
    Start, Finish: Int64;
    Increment, Level: Double;
  end;

  TToneBlock = record
    Start, Finish: Integer;
  end;

  TToneSequenceSource = class(TInterfacedObject, IAudioSource, IAudioMetadata, IAudioSeekSource)
  private
    FNotes: TArray<TToneNote>;
    FFrames, FPosition: Int64;
    FNoteIndex: Integer;
  public
    constructor Create(const Data: TBytes);
    function GetFormat: TAudioFormat;
    function GetInfo: TAudioInfo;
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
    function SeekFrame(Frame: Int64; const Cancelled: TFunc<Boolean>): Int64;
  end;

constructor TToneSequenceSource.Create(const Data: TBytes);
var
  Blocks: array[0..127] of TToneBlock;
  Notes: TList<TToneNote>;
  Cursor, Tempo, Resolution, Volume, Commands: Integer;
  Ticks: Int64;

  procedure Invalid;
  begin
    raise EArgumentException.Create('Invalid Java ME tone sequence');
  end;

  function ReadByte(var Offset: Integer): Integer;
  begin
    if Offset >= Length(Data) then
      Invalid;
    Result := ShortInt(Data[Offset]);
    Inc(Offset);
  end;

  procedure ReadEvent(var Offset: Integer; Emit: Boolean);
  begin
    var Tag := ReadByte(Offset);
    var Value := ReadByte(Offset);
    if Emit then
    begin
      Inc(Commands);
      if Commands > MaxCommands then
        raise EArgumentException.Create('Java ME tone block expansion limit');
    end;

    case Tag of
      J2METonePlayBlock:
        begin
          if (Value < 0) or (Blocks[Value].Finish = 0) then
            Invalid;
          if Emit then
          begin
            var BlockCursor := Blocks[Value].Start;
            while BlockCursor < Blocks[Value].Finish do
              ReadEvent(BlockCursor, True);
          end;
          Exit;
        end;
      J2METoneVolume:
        begin
          if not InRange(Value, 0, 100) then
            Invalid;
          if Emit then
            Volume := Value;
          Exit;
        end;
    end;

    var Repetitions := 1;
    if Tag = J2METoneRepeat then
    begin
      if Value < 2 then
        Invalid;
      Repetitions := Value;
      Tag := ReadByte(Offset);
      Value := ReadByte(Offset);
    end;
    if (Tag < J2METoneSilence) or (Value < 1) then
      Invalid;
    if not Emit then
      Exit;

    if Notes.Count + Repetitions > MaxNotes then
      raise EArgumentException.Create('Java ME tone note limit');
    var Note: TToneNote;
    Note.Increment := 0;
    Note.Level := 0;
    if (Tag >= 0) and (Volume > 0) then
    begin
      Note.Increment := 2 * Pi * (440 * Power(2, (Tag - 69) / 12)) / J2METoneRate;
      Note.Level := 16384 * Volume / 100;
    end;
    for var I := 1 to Repetitions do
    begin
      Note.Start := FFrames;
      Inc(Ticks, Value);
      // Round cumulative boundaries, keeping repeated fractional notes on time.
      FFrames := Ticks * FramesPerMinute div (Tempo * Resolution);
      if FFrames > MaxFrames then
        raise EArgumentException.Create('Java ME tone duration limit');
      Note.Finish := FFrames;
      Notes.Add(Note);
    end;
  end;

begin
  inherited Create;
  if (Length(Data) < 4) or (Length(Data) > J2METoneMaxBytes) then
    Invalid;
  Cursor := 0;
  if (ReadByte(Cursor) <> J2METoneVersion) or (ReadByte(Cursor) <> 1) then
    Invalid;

  Tempo := 30;
  if (Cursor < Length(Data)) and (ShortInt(Data[Cursor]) = J2METoneTempo) then
  begin
    Inc(Cursor);
    Tempo := ReadByte(Cursor);
    if Tempo < 5 then
      Invalid;
  end;
  Resolution := 64;
  if (Cursor < Length(Data)) and (ShortInt(Data[Cursor]) = J2METoneResolution) then
  begin
    Inc(Cursor);
    Resolution := ReadByte(Cursor);
    if Resolution < 1 then
      Invalid;
  end;

  FillChar(Blocks, SizeOf(Blocks), 0);
  // Blocks may only refer to fully defined earlier blocks, preventing cycles.
  while (Cursor < Length(Data)) and (ShortInt(Data[Cursor]) = J2METoneBlockStart) do
  begin
    Inc(Cursor);
    var Number := ReadByte(Cursor);
    if (Number < 0) or (Blocks[Number].Finish <> 0) then
      Invalid;
    Blocks[Number].Start := Cursor;
    while (Cursor < Length(Data)) and (ShortInt(Data[Cursor]) <> J2METoneBlockEnd) do
      ReadEvent(Cursor, False);
    var BlockEnd := Cursor;
    if (BlockEnd = Blocks[Number].Start) or (ReadByte(Cursor) <> J2METoneBlockEnd) or (ReadByte(Cursor) <> Number) then
      Invalid;
    Blocks[Number].Finish := BlockEnd;
  end;
  if Cursor = Length(Data) then
    Invalid;
  Volume := 100;
  Ticks := 0;
  Commands := 0;
  Notes := TList<TToneNote>.Create;
  try
    while Cursor < Length(Data) do
      ReadEvent(Cursor, True);
    FNotes := Notes.ToArray;
  finally
    Notes.Free;
  end;
end;

function TToneSequenceSource.GetFormat: TAudioFormat;
begin
  Result.SampleRate := J2METoneRate;
  Result.Channels := 1;
end;

function TToneSequenceSource.GetInfo: TAudioInfo;
begin
  Result := Default(TAudioInfo);
  Result.FormatName := 'Java ME tone sequence';
  Result.TrackCount := 1;
  Result.SampleRate := J2METoneRate;
  Result.Channels := 1;
  Result.TrackDurations := [FFrames / J2METoneRate];
end;

function TToneSequenceSource.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 1);
  Result := 0;
  while (Result < Frames) and (FNoteIndex < Length(FNotes)) do
  begin
    var Note := FNotes[FNoteIndex];
    var Count := Integer(Min(Int64(Frames - Result), Note.Finish - FPosition));
    if Note.Level = 0 then
      FillChar(Samples[Result], Count * SizeOf(SmallInt), 0)
    else
      for var I := 0 to Count - 1 do
        Samples[Result + I] := SmallInt(Round(Sin((FPosition - Note.Start + I) * Note.Increment) * Note.Level));
    Inc(Result, Count);
    Inc(FPosition, Count);
    if FPosition = Note.Finish then
      Inc(FNoteIndex);
  end;
end;

function TToneSequenceSource.SeekFrame(Frame: Int64; const Cancelled: TFunc<Boolean>): Int64;
begin
  if Assigned(Cancelled) and Cancelled() then
    raise EAbort.Create('Tone sequence seek cancelled');
  FPosition := EnsureRange(Frame, Int64(0), FFrames);
  var LowIndex := 0;
  var HighIndex := Length(FNotes);
  while LowIndex < HighIndex do
  begin
    var Middle := LowIndex + (HighIndex - LowIndex) div 2;
    if FNotes[Middle].Finish <= FPosition then
      LowIndex := Middle + 1
    else
      HighIndex := Middle;
  end;
  FNoteIndex := LowIndex;
  Result := FPosition;
end;

function OpenJ2METoneSequence(const Data: TBytes; out Frames: Int64): IAudioSource;
begin
  var Source := TToneSequenceSource.Create(Data);
  Frames := Source.FFrames;
  Result := Source;
end;

end.
