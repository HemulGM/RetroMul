unit PSP.UMDVideo;

// Native UMD Video playback. The ISO and MPS streams stay seekable and are
// read a pack at a time; no firmware or external codec libraries are required.
interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections,
  Core.Emulation.Types, PSP.Media, PSP.MpegDemux, Video.AVC.Types,
  Video.AVC.H264, Audio.ATRAC3Plus;

type
  TUMDChapter = record
    Name: string;
    Time: Int64; // Microseconds on the clip timeline.
  end;

  TUMDTitle = record
    Name, Clip: string;
    StartTime, EndTime: Int64;
    Chapters: TArray<TUMDChapter>;
  end;

  TUMDSeekPoint = record
    Time, Offset: Int64;
  end;

  TPSPUMDVideo = class
  private
    type
      TAudioBlock = record
        StartTime: Int64;
        Rate: Integer;
        Samples: TArray<SmallInt>;
      end;
  private
    FDisc: TPSPDisc;
    FStream: TStream;
    FTitles: TArray<TUMDTitle>;
    FSeek: TArray<TUMDSeekPoint>;
    FTitle: Integer;
    FDemux: TPSPPsDemux;
    FVideoQueue: TQueue<TVideoFrame>;
    FAudioQueue: TQueue<TAudioBlock>;
    FVideoES, FAudioES: TPSPEsQueue;
    FDecoder: TH264Decoder;
    FAtrac: TATRAC3PlusDecoder;
    FAudioBlock: TAudioBlock;
    FAudioEnd, FAudioNext, FVideoEnd, FTime, FStep, FNumber: Int64;
    FAudioPhase, FAudioBase, FAudioFrames: Int64;
    FAudioRate, FAudioChannels: Integer;
    FPaused, FEnded, FEOF, FFirstVideo: Boolean;
    FSeekTime: Int64;
    FButtons: TEmulatorButtons;
    FFrame: TEmulatorFrame;
    FPrerollPicture: TVideoFrame;
    FSamples: TArray<SmallInt>;
    procedure OpenTitle(Index: Integer);
    procedure DecodeAudio(const AU: TPSPAccessUnit);
    procedure Pump(UntilTime: Int64);
    procedure DisplayPicture(const Picture: TVideoFrame);
    function AudioSample(Time: Int64; Channel: Integer): SmallInt;
  public
    // Image belongs to the caller and must outlive the player.
    constructor Create(Image: TStream);
    destructor Destroy; override;
    class function ReadPlaylist(const Data: TBytes): TArray<TUMDTitle>; static;
    class function ReadSeekMap(const Data: TBytes; StreamSize: Int64): TArray<TUMDSeekPoint>; static;
    procedure Reset;
    procedure Seek(Time: Int64);
    procedure SelectTitle(Index: Integer);
    procedure Chapter(forward: Boolean);
    // True means the caller should discard sound queued before a seek/pause.
    function Control(const Input: TEmulatorInput): Boolean;
    procedure RunFrame(out Frame: TEmulatorFrame);
    function Status: string;
    property Titles: TArray<TUMDTitle> read FTitles;
    property TitleIndex: Integer read FTitle;
    property Position: Int64 read FTime;
    property Paused: Boolean read FPaused;
    property Ended: Boolean read FEnded;
    property AudioSamples: TArray<SmallInt> read FSamples;
  end;

implementation

uses
  System.Math, System.UITypes;

function BE(const Data: TBytes; At, Count: Integer): Cardinal;
begin
  if (At < 0) or (Count < 1) or (Int64(At) + Count > Length(Data)) then
    raise EPSPFormat.Create('UMD Video: truncated metadata');
  Result := 0;
  for var I := 0 to Count - 1 do
    Result := (Result shl 8) or Data[At + I];
end;

function Text(const Data: TBytes; At, Count: Integer): string;
begin
  if (At < 0) or (Count < 0) or (Int64(At) + Count > Length(Data)) then
    raise EPSPFormat.Create('UMD Video: truncated text');
  Result := TEncoding.UTF8.GetString(Data, At, Count).Trim([#0, ' ']);
end;

class function TPSPUMDVideo.ReadPlaylist(const Data: TBytes): TArray<TUMDTitle>;
begin
  Result := nil;
  if (Length(Data) < 16) or (Text(Data, 0, 4) <> 'UMDV') then
    raise EPSPFormat.Create('UMD Video: invalid playlist');
  var Base := Int64(BE(Data, 8, 4));
  if (Base > Length(Data) - 8) or (BE(Data, Base, 4) > Int64(Length(Data)) - Base - 4) then
    raise EPSPFormat.Create('UMD Video: invalid playlist bounds');
  var Limit := Base + 4 + BE(Data, Base, 4);
  var Count := BE(Data, Base + 4, 2);
  if (Count = 0) or (Count > 1024) then
    raise EPSPFormat.Create('UMD Video: invalid playlist count');
  SetLength(Result, Count);
  var At := Base + 8;
  for var I := 0 to Integer(Count) - 1 do
  begin
    if At + 820 > Limit then
      raise EPSPFormat.Create('UMD Video: truncated playlist entry');
    var N := BE(Data, At + 52, 1);
    Result[I].Name := Text(Data, At + 53, N);
    Inc(At, 795);
    N := BE(Data, At, 1);
    if (N = 0) or (N > 8) then
      raise EPSPFormat.Create('UMD Video: invalid clip name');
    Result[I].Clip := Text(Data, At + 1, N);
    for var C in Result[I].Clip do
      if not CharInSet(C, ['0'..'9', 'A'..'Z', 'a'..'z', '_', '-']) then
        raise EPSPFormat.Create('UMD Video: invalid clip path');
    Inc(At, 11);
    Result[I].StartTime := Int64(BE(Data, At, 4)) * PlayerTimeBase div 90000;
    Result[I].EndTime := Int64(BE(Data, At + 6, 4)) * PlayerTimeBase div 90000;
    if Result[I].EndTime <= Result[I].StartTime then
      raise EPSPFormat.Create('UMD Video: invalid title duration');
    Inc(At, 12);
    var MarkerBytes := BE(Data, At, 2);
    Inc(At, 2);
    if MarkerBytes <> 0 then
    begin
      var Markers := BE(Data, At, 2);
      if (Markers > 4096) or (At + 2 + Int64(Markers) * 40 > Limit) then
        raise EPSPFormat.Create('UMD Video: invalid chapter count');
      if MarkerBytes <> 2 + Markers * 40 then
        raise EPSPFormat.Create('UMD Video: invalid chapter table size');
      SetLength(Result[I].Chapters, Markers);
      Inc(At, 2);
      for var J := 0 to Integer(Markers) - 1 do
      begin
        N := BE(Data, At + 1, 1);
        if N > 24 then
          raise EPSPFormat.Create('UMD Video: invalid chapter name');
        Result[I].Chapters[J].Name := Text(Data, At + 16, N);
        Result[I].Chapters[J].Time := Int64(BE(Data, At + 6, 4)) * PlayerTimeBase div 90000;
        Inc(At, 40);
      end;
      Inc(At, 2);
    end;
  end;
end;

class function TPSPUMDVideo.ReadSeekMap(const Data: TBytes; StreamSize: Int64): TArray<TUMDSeekPoint>;
begin
  Result := nil;
  if (Length(Data) < 24) or (Text(Data, 0, 4) <> 'CLPI') then
    raise EPSPFormat.Create('UMD Video: invalid clip information');
  var Base := Int64(BE(Data, 12, 4));
  if (Base > Length(Data) - 18) or (BE(Data, Base + 6, 2) = 0) then
    Exit;
  // CPI's AVC entry-point table: stream id, count, relative table offset.
  if (BE(Data, Base + 8, 2) and $FF00) <> $E000 then
    Exit;
  var Count := BE(Data, Base + 10, 4);
  var At := Base + 6 + BE(Data, Base + 14, 4);
  if (Count > 1000000) or (At > Length(Data)) or (Int64(Count) * 10 > Length(Data) - At) then
    raise EPSPFormat.Create('UMD Video: invalid entry-point table');
  SetLength(Result, Count);
  for var I := 0 to Integer(Count) - 1 do
  begin
    Result[I].Time := Int64(BE(Data, At + 2, 4)) * PlayerTimeBase div 90000;
    Result[I].Offset := Int64(BE(Data, At + 6, 4)) * PSMFPacketSize;
    if (Result[I].Offset >= StreamSize) or ((I > 0) and
      ((Result[I].Time < Result[I - 1].Time) or (Result[I].Offset < Result[I - 1].Offset))) then
      raise EPSPFormat.Create('UMD Video: invalid entry point');
    Inc(At, 10);
  end;
end;

constructor TPSPUMDVideo.Create(Image: TStream);
begin
  inherited Create;
  FTitle := -1;
  FDisc := TPSPDisc.Create(Image);
  FVideoQueue := TQueue<TVideoFrame>.Create;
  FAudioQueue := TQueue<TAudioBlock>.Create;
  FTitles := ReadPlaylist(FDisc.ReadFile('UMD_VIDEO/PLAYLIST.UMD', 16 * 1024 * 1024));
  FFrame.Width := 480;
  FFrame.Height := 272;
  SetLength(FFrame.Pixels, 480 * 272);
  for var I := 0 to High(FFrame.Pixels) do
    FFrame.Pixels[I] := $FF000000;
  Reset;
end;

destructor TPSPUMDVideo.Destroy;
begin
  FStream.Free;
  FDecoder.Free;
  FAtrac.Free;
  FDemux.Free;
  FVideoQueue.Free;
  FAudioQueue.Free;
  FDisc.Free;
  inherited;
end;

procedure TPSPUMDVideo.Reset;
begin
  var Best := -1;
  var Duration := Int64(-1);
  for var I := 0 to High(FTitles) do
    if (FTitles[I].EndTime - FTitles[I].StartTime > Duration) and
      FDisc.HasFile('UMD_VIDEO/STREAM/' + FTitles[I].Clip + '.MPS') then
    begin
      Duration := FTitles[I].EndTime - FTitles[I].StartTime;
      Best := I;
    end;
  if Best < 0 then
    raise EPSPFormat.Create('UMD Video: no playable clips');
  FButtons := [];
  FPaused := False;
  OpenTitle(Best);
end;

procedure TPSPUMDVideo.OpenTitle(Index: Integer);
begin
  if (Index < 0) or (Index >= Length(FTitles)) then
    raise EArgumentOutOfRangeException.Create('UMD Video title');
  FreeAndNil(FStream);
  FTitle := Index;
  FStream := FDisc.OpenFile('UMD_VIDEO/STREAM/' + FTitles[Index].Clip + '.MPS');
  FSeek := nil;
  var Path := 'UMD_VIDEO/CLIPINF/' + FTitles[Index].Clip + '.CLP';
  if FDisc.HasFile(Path) then
    FSeek := ReadSeekMap(FDisc.ReadFile(Path, 16 * 1024 * 1024), FStream.Size);
  Seek(FTitles[Index].StartTime);
end;

procedure TPSPUMDVideo.SelectTitle(Index: Integer);
begin
  OpenTitle(Index);
  FPaused := False;
end;

procedure TPSPUMDVideo.Seek(Time: Int64);
begin
  FTime := EnsureRange(Time, FTitles[FTitle].StartTime, FTitles[FTitle].EndTime - 1);
  FStream.Position := 0;
  FSeekTime := FTitles[FTitle].StartTime;
  FFirstVideo := True;
  for var Point in FSeek do
    if Point.Time <= FTime then
    begin
      FStream.Position := Point.Offset;
      FSeekTime := Point.Time;
    end
    else
      Break;
  FreeAndNil(FDemux);
  FreeAndNil(FDecoder);
  FreeAndNil(FAtrac);
  FDemux := TPSPPsDemux.Create;
  FVideoES := FDemux.AddStream(PSMFKindAvc, $E0, 0);
  FAudioES := FDemux.AddStream(PSMFKindAtrac, $BD, 0);
  FDecoder := TH264Decoder.Create(True);
  FDecoder.ConfigureAnnexB(True);
  FDecoder.FillTimestampGaps := True;
  FAtrac := TATRAC3PlusDecoder.Create(2, 2);
  FPrerollPicture := Default(TVideoFrame);
  FVideoQueue.Clear;
  FAudioQueue.Clear;
  FAudioBlock := Default(TAudioBlock);
  FAudioNext := -1;
  FAudioFrames := 0;
  FAudioRate := 0;
  FAudioChannels := 2;
  FAudioEnd := -1;
  FVideoEnd := -1;
  FAudioPhase := 0;
  FStep := 0;
  FEOF := False;
  FEnded := False;
end;

procedure TPSPUMDVideo.Chapter(forward: Boolean);
begin
  var Target := FTitles[FTitle].StartTime;
  for var Mark in FTitles[FTitle].Chapters do
    if forward then
    begin
      if Mark.Time > FTime + 500000 then
      begin
        Target := Mark.Time;
        Break;
      end;
    end
    else if Mark.Time < FTime - 2000000 then
      Target := Mark.Time;
  if forward and (Target = FTitles[FTitle].StartTime) then
    Target := FTitles[FTitle].EndTime - 1;
  Seek(Target);
end;

function TPSPUMDVideo.Control(const Input: TEmulatorInput): Boolean;
begin
  var Pressed := Input.Buttons - FButtons;
  FButtons := Input.Buttons;
  Result := Pressed * [TEmulatorButton.Start, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.C, TEmulatorButton.Z, TEmulatorButton.Select] <> [];
  if TEmulatorButton.Start in Pressed then
  begin
    if FEnded then
    begin
      Seek(FTitles[FTitle].StartTime);
      FPaused := False;
    end
    else
      FPaused := not FPaused;
  end;
  if TEmulatorButton.Left in Pressed then
    Seek(FTime - 10000000);
  if TEmulatorButton.Right in Pressed then
    Seek(FTime + 10000000);
  if TEmulatorButton.C in Pressed then
    Chapter(False);
  if TEmulatorButton.Z in Pressed then
    Chapter(True);
  if TEmulatorButton.Select in Pressed then
  begin
    // Cycle complete clips, skipping alternate chapter-only playlist entries.
    var Next := FTitle;
    for var N := 1 to Length(FTitles) do
    begin
      var I := (FTitle + N) mod Length(FTitles);
      var Best := True;
      for var J := 0 to High(FTitles) do
        if SameText(FTitles[I].Clip, FTitles[J].Clip) and
          (FTitles[J].EndTime - FTitles[J].StartTime > FTitles[I].EndTime - FTitles[I].StartTime) then
          Best := False;
      if Best and not SameText(FTitles[I].Clip, FTitles[FTitle].Clip) then
      begin
        Next := I;
        Break;
      end;
    end;
    if Next <> FTitle then
      SelectTitle(Next);
  end;
end;

procedure TPSPUMDVideo.DecodeAudio(const AU: TPSPAccessUnit);
const
  Rates: array[0..7] of Integer = (32000, 44100, 48000, 88200, 96000, 0, 0, 0);
begin
  if Length(AU.Data) < 8 then
    raise EPSPFormat.Create('UMD Video: truncated ATRAC3+ frame');
  var Params := (Integer(AU.Data[2]) shl 8) or AU.Data[3];
  var Rate := Rates[(Params shr 13) and 7];
  if Rate = 0 then
    raise EPSPFormat.Create('UMD Video: invalid audio sample rate');
  var Channels := (Params shr 10) and 7;
  if not (Channels in [1, 2]) then
    raise EPlayerUnsupported.Create('UMD Video: unsupported ATRAC3+ channel configuration');
  if Channels <> FAudioChannels then
  begin
    FreeAndNil(FAtrac);
    FAtrac := TATRAC3PlusDecoder.Create(Channels, 2);
    FAudioChannels := Channels;
  end;
  var Block := Default(TAudioBlock);
  Block.Rate := Rate;
  Block.Samples := FAtrac.Decode(Copy(AU.Data, 8, Length(AU.Data) - 8));
  if (AU.Pts >= 0) or (FAudioRate <> Rate) then
  begin
    if AU.Pts >= 0 then
      FAudioBase := AU.Pts * PlayerTimeBase div 90000
    else
      FAudioBase := FSeekTime;
    FAudioFrames := 0;
    FAudioRate := Rate;
  end;
  Block.StartTime := FAudioBase + FAudioFrames * PlayerTimeBase div Rate;
  Inc(FAudioFrames, Length(Block.Samples) div 2);
  FAudioNext := FAudioBase + FAudioFrames * PlayerTimeBase div Rate;
  FAudioEnd := FAudioNext;
  if FAudioEnd >= FTime then
    FAudioQueue.Enqueue(Block);
end;

procedure TPSPUMDVideo.Pump(UntilTime: Int64);
var
  Pack: array[0..PSMFPacketSize - 1] of Byte;
  AU: TPSPAccessUnit;
  Picture: TVideoFrame;
begin
  var Packs := 0;
  while not FEOF and ((FVideoEnd < UntilTime) or (FAudioEnd < UntilTime)) do
  begin
    var Remaining := FStream.Size - FStream.Position;
    if Remaining < PSMFPacketSize then
    begin
      if Remaining <> 0 then
        raise EPSPFormat.Create('UMD Video: incomplete program-stream pack');
      FEOF := True;
    end
    else
    begin
      FStream.ReadBuffer(Pack, SizeOf(Pack));
      FDemux.FeedPack(@Pack[0]);
    end;
    while FDemux.NextAu(FVideoES, AU, FEOF) do
    begin
      var Packet := Default(TMediaPacket);
      Packet.Data := AU.Data;
      Packet.PTS := -1;
      Packet.DTS := -1;
      if AU.Pts >= 0 then
        Packet.PTS := AU.Pts * PlayerTimeBase div 90000;
      if AU.Dts >= 0 then
        Packet.DTS := AU.Dts * PlayerTimeBase div 90000;
      if FFirstVideo then
      begin
        if Packet.PTS < 0 then
          Packet.PTS := FSeekTime;
        FFirstVideo := False;
      end;
      FDecoder.SendAnnexB(Packet);
      while FDecoder.Receive(Picture) do
      begin
        FVideoEnd := Max(FVideoEnd, Picture.PTS + Picture.Duration);
        if Picture.PTS >= FTime then
          FVideoQueue.Enqueue(Picture)
        else if (Length(FPrerollPicture.Planes[0]) = 0) or (Picture.PTS > FPrerollPicture.PTS) then
          FPrerollPicture := Picture;
      end;
    end;
    while FDemux.NextAu(FAudioES, AU, FEOF) do
      DecodeAudio(AU);
    FDemux.TakeFreed;
    if (FVideoES.Length > 8 * 1024 * 1024) or (FAudioES.Length > 1024 * 1024) or
      (FAudioQueue.Count > 128) then
      raise EPSPFormat.Create('UMD Video: streams exceed the bounded playback buffer');
    if FEOF then
    begin
      FDecoder.Flush;
      while FDecoder.Receive(Picture) do
      begin
        FVideoEnd := Max(FVideoEnd, Picture.PTS + Picture.Duration);
        FVideoQueue.Enqueue(Picture);
      end;
    end;
    Inc(Packs);
    // Bound silent/corrupt inputs and keep the frontend responsive during seeks.
    if (Packs >= 2048) or (FVideoQueue.Count >= 96) then
      Break;
  end;
end;

function TPSPUMDVideo.AudioSample(Time: Int64; Channel: Integer): SmallInt;
begin
  Result := 0;
  while (Length(FAudioBlock.Samples) = 0) or
    (Time >= FAudioBlock.StartTime + Int64(Length(FAudioBlock.Samples) div 2) * PlayerTimeBase div Max(FAudioBlock.Rate, 1)) do
  begin
    if FAudioQueue.Count = 0 then
      Exit;
    if FAudioQueue.Peek.StartTime > Time then
      Exit;
    FAudioBlock := FAudioQueue.Dequeue;
  end;
  if Time < FAudioBlock.StartTime then
    Exit;
  var Position := (Time - FAudioBlock.StartTime) * FAudioBlock.Rate;
  var I := Position div PlayerTimeBase;
  var Fraction := Position mod PlayerTimeBase;
  var Last := Length(FAudioBlock.Samples) div 2 - 1;
  if I > Last then
    Exit;
  var A := Integer(FAudioBlock.Samples[I * 2 + Channel]);
  var B := A;
  if I < Last then
    B := FAudioBlock.Samples[(I + 1) * 2 + Channel]
  else if (FAudioQueue.Count > 0) and (Length(FAudioQueue.Peek.Samples) >= 2) then
    B := FAudioQueue.Peek.Samples[Channel];
  Result := A + (Int64(B - A) * Fraction div PlayerTimeBase);
end;

procedure TPSPUMDVideo.DisplayPicture(const Picture: TVideoFrame);
begin
  // Honor the AVC sample aspect ratio, fitting the picture to the PSP screen.
  var Pixels: TArray<TAlphaColor>;
  SetLength(Pixels, 480 * 272);
  for var I := 0 to High(Pixels) do
    Pixels[I] := $FF000000;
  var Width := 480;
  var Height := 272;
  if (Picture.SampleAspectNumerator > 0) and (Picture.SampleAspectDenominator > 0) then
  begin
    var N := Int64(Picture.Width) * Picture.SampleAspectNumerator;
    var D := Int64(Picture.Height) * Picture.SampleAspectDenominator;
    if N * 272 >= D * 480 then
      Height := Max(1, 480 * D div N)
    else
      Width := Max(1, 272 * N div D);
  end;
  var Left := (480 - Width) div 2;
  var Top := (272 - Height) div 2;
  for var Y := 0 to Height - 1 do
    for var X := 0 to Width - 1 do
    begin
      var SX := X * Picture.Width div Width;
      var SY := Y * Picture.Height div Height;
      var L := Integer(Picture.Planes[0][SY * Picture.Strides[0] + SX]);
      var U := Integer(Picture.Planes[1][(SY div 2) * Picture.Strides[1] + SX div 2]) - 128;
      var V := Integer(Picture.Planes[2][(SY div 2) * Picture.Strides[2] + SX div 2]) - 128;
      var C := L - 16;
      var R, G, B: Integer;
      if Picture.FullRange then
      begin
        R := L + (359 * V + 128) div 256;
        G := L - (88 * U + 183 * V + 128) div 256;
        B := L + (454 * U + 128) div 256;
      end
      else if Picture.Matrix = TColorMatrix.BT709 then
      begin
        R := (EnsureRange(298 * C + 459 * V + 128, 0, 65535)) shr 8;
        G := (EnsureRange(298 * C - 55 * U - 136 * V + 128, 0, 65535)) shr 8;
        B := (EnsureRange(298 * C + 541 * U + 128, 0, 65535)) shr 8;
      end
      else
      begin
        R := (EnsureRange(298 * C + 409 * V + 128, 0, 65535)) shr 8;
        G := (EnsureRange(298 * C - 100 * U - 208 * V + 128, 0, 65535)) shr 8;
        B := (EnsureRange(298 * C + 516 * U + 128, 0, 65535)) shr 8;
      end;
      Pixels[(Y + Top) * 480 + X + Left] := $FF000000 or (Cardinal(EnsureRange(R, 0, 255)) shl 16) or
        (Cardinal(EnsureRange(G, 0, 255)) shl 8) or Cardinal(EnsureRange(B, 0, 255));
    end;
  FFrame.Pixels := Pixels;
end;

procedure TPSPUMDVideo.RunFrame(out Frame: TEmulatorFrame);
begin
  // 60000/1001 display ticks; keep both clocks rational to avoid drift.
  Inc(FAudioPhase, Int64(44100) * 1001);
  var Count := FAudioPhase div 60000;
  FAudioPhase := FAudioPhase mod 60000;
  SetLength(FSamples, Count * 2);
  if FPaused or FEnded then
    FillChar(FSamples[0], Length(FSamples) * SizeOf(SmallInt), 0)
  else
  begin
    var Start := FTime;
    var Next := FTime + ((FStep + 1) * 1001 * PlayerTimeBase div 60000 - FStep * 1001 * PlayerTimeBase div 60000);
    Pump(Next);
    // A long seek can span more than one bounded pump. Finish preroll
    // before advancing the playback clock or emitting sound.
    if not FEOF and (FVideoEnd < Start) then
      FillChar(FSamples[0], Length(FSamples) * SizeOf(SmallInt), 0)
    else
    begin
      if Length(FPrerollPicture.Planes[0]) <> 0 then
      begin
        DisplayPicture(FPrerollPicture);
        FPrerollPicture := Default(TVideoFrame);
      end;
      while (FVideoQueue.Count > 0) and (FVideoQueue.Peek.PTS <= Start) do
        DisplayPicture(FVideoQueue.Dequeue);
      for var I := 0 to Integer(Count) - 1 do
      begin
        var Time := Start + Int64(I) * PlayerTimeBase div 44100;
        FSamples[I * 2] := AudioSample(Time, 0);
        FSamples[I * 2 + 1] := AudioSample(Time, 1);
      end;
      FTime := Next;
      Inc(FStep);
      FEnded := (FTime >= FTitles[FTitle].EndTime) or (FEOF and (FVideoQueue.Count = 0) and (FTime >= FVideoEnd));
    end;
  end;
  Inc(FNumber);
  FFrame.FrameNumber := FNumber;
  FFrame.FramesPerSecond := 60000 / 1001;
  Frame := FFrame;
end;

function TPSPUMDVideo.Status: string;
begin
  var Seconds := Max(Int64(0), (FTime - FTitles[FTitle].StartTime) div PlayerTimeBase);
  Result := Format('UMD Video | %s | %d:%2.2d | Start: pause; Left/Right: 10 s; L/R: chapter; Select: title',
    [FTitles[FTitle].Name, Seconds div 60, Seconds mod 60]);
  if FPaused then
    Result := Result + ' | Paused';
  if FEnded then
    Result := Result + ' | End';
end;

end.

