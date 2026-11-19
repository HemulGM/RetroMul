unit J2ME.IMelody;

interface

uses
  System.SysUtils, Audio.Types;

const
  IMelodyContentType = 'audio/imelody';
  IMelodySampleRate = 44100;
  IMelodyMaxBytes = 256 * 1024;

type
  IIMelodyEffects = interface
    ['{D03535A9-B831-45C6-8485-FEDB03BF2B46}']
    function VibratesAt(Frame: Int64): Boolean;
  end;

function IsIMelody(const Data: TBytes): Boolean;

function IsIMelodyContentType(const Name: string): Boolean;

function OpenIMelody(const Data: TBytes; out Frames: Int64): IAudioSource;

implementation

uses
  System.Math, System.Generics.Collections, Audio.Decoder;

const
  Header = 'BEGIN:IMELODY';
  Footer = 'END:IMELODY';
  QuarterTicks = 192;
  MaxCommands = 32768;
  MaxFrames = Int64(IMelodySampleRate) * 86400;

type
  TMelodySpan = record
    Start, AudibleEnd, Finish: Int64;
    Step, Level: Double;
    Vibrates: Boolean;
  end;

  TMelodySource = class(TInterfacedObject, IAudioSource, IAudioMetadata, IAudioSeekSource, IIMelodyEffects)
  private
    FSpans: TArray<TMelodySpan>;
    FFrames, FPosition: Int64;
    FIndex: Integer;
    function SpanAt(Frame: Int64): Integer;
  public
    constructor Create(const Data: TBytes);
    function GetFormat: TAudioFormat;
    function GetInfo: TAudioInfo;
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
    function SeekFrame(Frame: Int64; const Cancelled: TFunc<Boolean>): Int64;
    function VibratesAt(Frame: Int64): Boolean;
  end;

procedure Invalid(const Detail: string);
begin
  raise EArgumentException.Create('Invalid iMelody: ' + Detail);
end;

function TextOffset(const Data: TBytes): Integer;
begin
  Result := 0;
  if (Length(Data) >= 3) and (Data[0] = $EF) and (Data[1] = $BB) and (Data[2] = $BF) then
    Result := 3;
end;

function IsIMelody(const Data: TBytes): Boolean;
begin
  var Offset := TextOffset(Data);
  Result := (Length(Data) >= Offset + Length(Header)) and
    SameText(TEncoding.ASCII.GetString(Data, Offset, Length(Header)), Header);
end;

function IsIMelodyContentType(const Name: string): Boolean;
begin
  Result := (Name = IMelodyContentType) or (Name = 'audio/x-imelody') or (Name = 'text/x-imelody');
end;

constructor TMelodySource.Create(const Data: TBytes);
var
  Beat, Style, Volume, Octave, Commands, Offset, LoopStart, Remaining: Integer;
  Ticks: Int64;
  Text: string;
  Spans: TList<TMelodySpan>;
  Vibrate: Boolean;

  function Current: Char;
  begin
    if Offset > Length(Text) then
      Exit(#0);
    Result := Text[Offset];
  end;

  procedure SkipSpace;
  begin
    while CharInSet(Current, [' ', #9]) do
      Inc(Offset);
  end;

  function Take(const Token: string): Boolean;
  begin
    Result := Copy(Text, Offset, Length(Token)) = Token;
    if Result then
      Inc(Offset, Length(Token));
  end;

  function Number(Limit: Integer): Integer;
  begin
    Result := 0;
    if not CharInSet(Current, ['0'..'9']) then
      Invalid('expected number');
    repeat
      Result := 10 * Result + Ord(Current) - Ord('0');
      if Result > Limit then
        Invalid('number out of range');
      Inc(Offset);
    until not CharInSet(Current, ['0'..'9']);
  end;

  procedure ReadVolume(AllowAbsolute: Boolean);
  begin
    if Take('+') then
      Volume := Min(Volume + 1, 15)
    else if Take('-') then
      Volume := Max(Volume - 1, 0)
    else if AllowAbsolute then
      Volume := Number(15)
    else
      Invalid('expected relative volume');
  end;

  procedure Note;
  const
    Pitches: array['a'..'g'] of Integer = (9, 11, 0, 2, 4, 5, 7);
  begin
    if Take('*') then
    begin
      if not CharInSet(Current, ['0'..'8']) then
        Invalid('octave');
      Octave := Ord(Current) - Ord('0');
      Inc(Offset);
      if Current = 'r' then
        Invalid('octave before rest');
    end;
    var Accidental := 0;
    if Take('#') then
      Accidental := 1
    else if Take('&') then
      Accidental := -1;
    var Pitch := Current;
    Inc(Offset);
    if not CharInSet(Pitch, ['a'..'g', 'r']) or
      ((Accidental = 1) and not CharInSet(Pitch, ['a', 'c', 'd', 'f', 'g'])) or
      ((Accidental = -1) and not CharInSet(Pitch, ['a', 'b', 'd', 'e', 'g'])) then
      Invalid('note');
    if not CharInSet(Current, ['0'..'5']) then
      Invalid('duration');
    var Duration := (4 * QuarterTicks) shr (Ord(Current) - Ord('0'));
    Inc(Offset);
    if Take('.') then
      Duration := Duration * 3 div 2
    else if Take(':') then
      Duration := Duration * 7 div 4
    else if Take(';') then
      Duration := Duration * 2 div 3;

    var Span := Default(TMelodySpan);
    Span.Start := FFrames;
    Span.Vibrates := Vibrate;
    Inc(Ticks, Duration);
    FFrames := Ticks * (Int64(IMelodySampleRate) * 60) div (QuarterTicks * Beat);
    if FFrames > MaxFrames then
      Invalid('duration limit');
    Span.Finish := FFrames;
    Span.AudibleEnd := Span.Finish;
    if (Pitch <> 'r') and (Volume <> 0) then
    begin
      var MIDI := 24 + 12 * Octave + Pitches[Pitch] + Accidental;
      Span.Step := (2 * Pi * 440 / IMelodySampleRate) * Power(2, (MIDI - 69) / 12);
      Span.Level := (16384 / 15) * Volume;
      case Style of
        0:
          Span.AudibleEnd := Span.Start + (Span.Finish - Span.Start) * 20 div 21;
        2:
          Span.AudibleEnd := Span.Start + (Span.Finish - Span.Start) div 2;
      end;
    end;
    Spans.Add(Span);
  end;

  procedure ReadHeaders;
  begin
    if (Length(Data) > IMelodyMaxBytes) or not IsIMelody(Data) then
      Invalid('header or size');
    var Start := TextOffset(Data);
    var Lines := TEncoding.UTF8.GetString(Data, Start, Length(Data) - Start).Replace(#13#10, #10).Split([#10]);
    if not SameText(Trim(Lines[0]), Header) then
      Invalid('header');
    var Version := '';
    var FormatName := '';
    var FoundMelody := False;
    var Ended := False;
    var Melody := TStringBuilder.Create;
    try
      for var I := 1 to High(Lines) do
      begin
        var Line := Lines[I];
        if Trim(Line) = '' then
          Continue;
        if Ended then
          Invalid('data after footer');
        if FoundMelody and CharInSet(Line[1], [' ', #9]) then
        begin
          Melody.Append(Line, 1, Length(Line) - 1);
          Continue;
        end;
        if SameText(Trim(Line), Footer) then
        begin
          Ended := True;
          Continue;
        end;
        var Separator := Pos(':', Line);
        if (Separator = 0) or FoundMelody then
          Invalid('header field');
        var Name := UpperCase(Copy(Line, 1, Separator - 1));
        var Value := Trim(Copy(Line, Separator + 1));
        if Name = 'VERSION' then
          Version := Value
        else if Name = 'FORMAT' then
          FormatName := Value
        else if Name = 'BEAT' then
        begin
          Text := Value;
          Offset := 1;
          Beat := Number(900);
          if (Beat < 25) or (Offset <= Length(Text)) then
            Invalid('beat');
        end
        else if Name = 'STYLE' then
        begin
          Text := Value;
          Offset := 1;
          Take('S');
          Style := Number(2);
          if Offset <= Length(Text) then
            Invalid('style');
        end
        else if Name = 'VOLUME' then
        begin
          Text := Value;
          Offset := 1;
          Take('V');
          ReadVolume(True);
          if Offset <= Length(Text) then
            Invalid('volume');
        end
        else if Name = 'MELODY' then
        begin
          FoundMelody := True;
          Melody.Append(Value);
        end
        else if (Name <> 'NAME') and (Name <> 'COMPOSER') then
          Invalid('unknown header field');
      end;
      if not Ended or not FoundMelody or (Melody.Length = 0) or
        ((Version <> '1.0') and (Version <> '1.2')) or (FormatName <> 'CLASS1.0') then
        Invalid('incomplete melody or unsupported version');
      Text := Melody.ToString;
    finally
      Melody.Free;
    end;
  end;

begin
  inherited Create;
  Beat := 120;
  Style := 0;
  Volume := 7;
  ReadHeaders;
  Octave := 4;
  Offset := 1;
  LoopStart := 0;
  Remaining := -1;
  Commands := 0;
  Ticks := 0;
  Vibrate := False;
  Spans := TList<TMelodySpan>.Create;
  try
    SkipSpace;
    while Offset <= Length(Text) do
    begin
      Inc(Commands);
      if Commands > MaxCommands then
        Invalid('command limit');
      if Take('(') then
      begin
        if LoopStart <> 0 then
          Invalid('nested repeat');
        LoopStart := Offset;
      end
      else if Take('@') then
      begin
        if LoopStart = 0 then
          Invalid('repeat outside a group');
        var Count := Number(MaxCommands);
        if Count = 0 then
          Invalid('unbounded repeat');
        SkipSpace;
        if Take('V') then
          ReadVolume(False);
        if not Take(')') then
          Invalid('unterminated repeat');
        if Remaining = -1 then
          Remaining := Count;
        Dec(Remaining);
        if Remaining > 0 then
          Offset := LoopStart
        else
        begin
          LoopStart := 0;
          Remaining := -1;
        end;
      end
      else if Take(')') then
      begin
        // Sony Ericsson uses a group without a repeat count for one-shot vibration.
        if LoopStart = 0 then
          Invalid('unexpected closing parenthesis');
        LoopStart := 0;
      end
      else if Take('V') then
        ReadVolume(True)
      else if Take('vibeon') then
        Vibrate := True
      else if Take('vibeoff') then
        Vibrate := False
      else if not (Take('ledon') or Take('ledoff') or Take('backon') or Take('backoff')) then
        Note;
      SkipSpace;
    end;
    if LoopStart <> 0 then
      Invalid('unterminated group');
    if FFrames = 0 then
      Invalid('no timed events');
    FSpans := Spans.ToArray;
  finally
    Spans.Free;
  end;
end;

function TMelodySource.GetFormat: TAudioFormat;
begin
  Result.SampleRate := IMelodySampleRate;
  Result.Channels := 1;
end;

function TMelodySource.GetInfo: TAudioInfo;
begin
  Result := Default(TAudioInfo);
  Result.FormatName := 'iMelody';
  Result.TrackCount := 1;
  Result.SampleRate := IMelodySampleRate;
  Result.Channels := 1;
  Result.TrackDurations := [FFrames / IMelodySampleRate];
end;

function TMelodySource.SpanAt(Frame: Int64): Integer;
begin
  Result := 0;
  var Last := Length(FSpans);
  while Result < Last do
  begin
    var Middle := Result + (Last - Result) div 2;
    if FSpans[Middle].Finish <= Frame then
      Result := Middle + 1
    else
      Last := Middle;
  end;
end;

function TMelodySource.VibratesAt(Frame: Int64): Boolean;
begin
  var Index := SpanAt(Frame);
  Result := (Index < Length(FSpans)) and FSpans[Index].Vibrates;
end;

function TMelodySource.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 1);
  Result := 0;
  while (Result < Frames) and (FIndex < Length(FSpans)) do
  begin
    var Span := FSpans[FIndex];
    var Count := Integer(Min(Int64(Frames - Result), Span.Finish - FPosition));
    var Audible := 0;
    if Span.Level <> 0 then
      Audible := Integer(EnsureRange(Span.AudibleEnd - FPosition, Int64(0), Int64(Count)));
    for var I := 0 to Audible - 1 do
      Samples[Result + I] := SmallInt(Round(Sin((FPosition - Span.Start + I) * Span.Step) * Span.Level));
    if Audible < Count then
      FillChar(Samples[Result + Audible], (Count - Audible) * SizeOf(SmallInt), 0);
    Inc(Result, Count);
    Inc(FPosition, Count);
    if FPosition = Span.Finish then
      Inc(FIndex);
  end;
end;

function TMelodySource.SeekFrame(Frame: Int64; const Cancelled: TFunc<Boolean>): Int64;
begin
  if Assigned(Cancelled) and Cancelled() then
    raise EAbort.Create('iMelody seek cancelled');
  FPosition := EnsureRange(Frame, Int64(0), FFrames);
  FIndex := SpanAt(FPosition);
  Result := FPosition;
end;

function OpenIMelody(const Data: TBytes; out Frames: Int64): IAudioSource;
begin
  var Source := TMelodySource.Create(Data);
  Frames := Source.FFrames;
  Result := Source;
end;

end.

