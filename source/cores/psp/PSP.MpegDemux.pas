unit PSP.MpegDemux;

// PSMF headers and the MPEG-2 program stream inside them: 2048-byte packs
// carrying H.264 (0xE0..), ATRAC3+/PCM (private stream 1, sub-stream id) and
// the private stream 2 tables that give every video access unit's size.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Generics.Collections;

const
  PSMFPacketSize = 2048;
  PSMFNoTimestamp = Int64(-1);

  PSMFKindAvc = 0;
  PSMFKindAtrac = 1;
  PSMFKindPcm = 2;
  PSMFKindData = 3;

type
  TPSPPsmfEntry = record
    Index, PicOffset: Integer;
    Pts: Int64;
    Offset: Cardinal;
  end;

  TPSPPsmfStream = record
    StreamId, PrivateId: Byte;
    Kind: Integer;
    // Number of the stream among those of its kind.
    Number: Integer;
    Width, Height: Integer;
    Channels, Frequency: Integer;
    EPMapOffset, EPMapCount: Cardinal;
    EP: TArray<TPSPPsmfEntry>;
  end;

  TPSPPsmfHeader = record
    Valid: Boolean;
    Version: Cardinal;
    HeaderSize, StreamSize: Cardinal;
    StartTime, EndTime: Int64;
    MuxRate: Cardinal;
    Streams: TArray<TPSPPsmfStream>;
    // 0 or an sceMpeg/scePsmf error code.
    function Parse(const Data: TBytes): Cardinal;
    function Count(Kind: Integer): Integer;
    function Find(Kind, Number: Integer): Integer;
  end;

  TPSPAccessUnit = record
    Data: TBytes;
    Pts, Dts: Int64;
    // Video: the table's flags for the unit (bit 7 set but for the last of a group).
    Flags: Cardinal;
  end;

  TPSPTimeMark = record
    EsOffset: Int64;
    Pts, Dts: Int64;
  end;

  // One elementary stream gathered from the packs.
  TPSPEsQueue = class
  private
    FData: TBytes;
    FStart, FLength: Integer;
  public
    StreamId, PrivateId: Byte;
    Kind: Integer;
    Active: Boolean;
    // ES bytes appended / taken so far.
    TotalIn, TotalOut: Int64;
    Marks: TList<TPSPTimeMark>;
    // Access unit sizes from the private stream 2 tables, flags in the high half.
    Sizes: TQueue<Cardinal>;
    // Audio: bytes before the first frame header still to drop.
    AudioSkip: Integer;
    AudioStarted: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    // Drops what is buffered; the packs that carried it are then free.
    procedure Discard;
    procedure Append(const Src; Count: Integer);
    function Peek(Offset: Integer): Byte; inline;
    procedure Take(Count: Integer; out Dest: TBytes);
    procedure Drop(Count: Integer);
    property Length: Integer read FLength;
  end;

  // The streams a pack carried data for and where that data ends in each.
  TPSPPackInfo = record
    Count: Integer;
    Queue: array[0..3] of TPSPEsQueue;
    EsEnd: array[0..3] of Int64;
  end;

  // Parses packs in order and hands out access units. Packs are kept (as
  // pending) until every byte they carried for an active stream was taken.
  TPSPPsDemux = class
  private
    FQueues: TObjectList<TPSPEsQueue>;
    FPending: TQueue<TPSPPackInfo>;
    FPack: TPSPPackInfo;
    FParsed: Int64;
    procedure ParsePes(const P: PByte; Len: Integer; StreamId: Byte);
    procedure ParseTable(const P: PByte; Len: Integer);
    function QueueFor(StreamId, PrivateId: Byte): TPSPEsQueue;
    procedure TakeMarks(Q: TPSPEsQueue; Start, Size: Int64; out Pts, Dts: Int64);
    function VideoAuSize(Q: TPSPEsQueue): Integer;
    function AudioAuSize(Q: TPSPEsQueue): Integer;
    procedure SkipAudioJunk(Q: TPSPEsQueue);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    // Streams whose data is kept. Others are skipped.
    function AddStream(Kind: Integer; StreamId, PrivateId: Byte): TPSPEsQueue;
    procedure RemoveStream(Q: TPSPEsQueue);
    procedure FeedPack(const Pack: PByte);
    // Packs fully used since the last call.
    function TakeFreed: Integer;
    // Next access unit of a stream; False when it is not complete yet.
    // Final: no more data will come, the rest of the stream is one unit.
    function NextAu(Q: TPSPEsQueue; out Au: TPSPAccessUnit; Final: Boolean = False): Boolean;
    function HasAu(Q: TPSPEsQueue; Final: Boolean = False): Boolean;
    function Held: Integer;
    property Parsed: Int64 read FParsed;
    property Queues: TObjectList<TPSPEsQueue> read FQueues;
  end;

// Whether the packs from Start on carry data for a stream (looks at the first MaxPacks).
function PSMFStreamPresent(const Data: TBytes; Start: Integer; StreamId, PrivateId: Byte;
  MaxPacks: Integer = 512): Boolean;
function PSMFBE16(const P: PByte): Cardinal; inline;
function PSMFBE32(const P: PByte): Cardinal; inline;
function PSMFReadTimestamp(const P: PByte): Int64;
// ATRAC3+ frame size in PSMF (with its 8-byte header) from the header bytes.
function PSMFAtracFrameSize(B2, B3: Byte): Integer;

implementation

function PSMFBE16(const P: PByte): Cardinal;
begin
  Result := (Cardinal(P[0]) shl 8) or P[1];
end;

function PSMFBE32(const P: PByte): Cardinal;
begin
  Result := (Cardinal(P[0]) shl 24) or (Cardinal(P[1]) shl 16) or (Cardinal(P[2]) shl 8) or P[3];
end;

function PSMFReadTimestamp(const P: PByte): Int64;
begin
  Result := (Int64((P[0] shr 1) and 7) shl 30) or (Int64(P[1]) shl 22) or (Int64(P[2] shr 1) shl 15) or
    (Int64(P[3]) shl 7) or (P[4] shr 1);
end;

function PSMFAtracFrameSize(B2, B3: Byte): Integer;
begin
  Result := ((((Integer(B2) shl 8) or B3) and $3FF) + 1) * 8 + 8;
end;

function PSMFStreamPresent(const Data: TBytes; Start: Integer; StreamId, PrivateId: Byte; MaxPacks: Integer): Boolean;
begin
  var Pack := Start;
  var N := 0;
  while (Pack + PSMFPacketSize <= Length(Data)) and (N < MaxPacks) do
  begin
    var P := 0;
    var Base := PByte(@Data[Pack]);
    while P + 6 <= PSMFPacketSize do
    begin
      if (Base[P] <> 0) or (Base[P + 1] <> 0) or (Base[P + 2] <> 1) then
        Break;
      var Id := Base[P + 3];
      if Id = $BA then
      begin
        if P + 14 > PSMFPacketSize then
          Break;
        Inc(P, 14 + (Base[P + 13] and 7));
        Continue;
      end;
      var Len := Integer(PSMFBE16(Base + P + 4));
      if Id = StreamId then
      begin
        if Id <> $BD then
          Exit(True);
        var H := P + 6 + 3 + Base[P + 8];
        if (H < PSMFPacketSize) and (Base[H] = PrivateId) then
          Exit(True);
      end;
      Inc(P, 6 + Len);
    end;
    Inc(Pack, PSMFPacketSize);
    Inc(N);
  end;
  Result := False;
end;

function BE48(const P: PByte): Int64;
begin
  Result := (Int64(P[0]) shl 40) or (Int64(P[1]) shl 32) or (Int64(PSMFBE32(P + 2)));
end;

{ TPSPPsmfHeader }

function TPSPPsmfHeader.Parse(const Data: TBytes): Cardinal;
begin
  Self := Default(TPSPPsmfHeader);
  if Length(Data) < $82 then
    Exit(Cardinal($80615002));
  if (Data[0] <> Ord('P')) or (Data[1] <> Ord('S')) or (Data[2] <> Ord('M')) or (Data[3] <> Ord('F')) then
    Exit(Cardinal($80615002));
  Version := PCardinal(@Data[4])^;
  HeaderSize := PSMFBE32(@Data[8]);
  StreamSize := PSMFBE32(@Data[12]);
  StartTime := BE48(@Data[$54]);
  EndTime := BE48(@Data[$5A]);
  MuxRate := PSMFBE32(@Data[$60]);
  var Count := Data[$81];
  var Numbers: array[0..3] of Integer;
  FillChar(Numbers, SizeOf(Numbers), 0);
  for var I := 0 to Count - 1 do
  begin
    var O := $82 + I * 16;
    if O + 16 > Length(Data) then
      Break;
    var S := Default(TPSPPsmfStream);
    S.StreamId := Data[O];
    S.PrivateId := Data[O + 1];
    if (S.StreamId and $F0) = $E0 then
    begin
      S.Kind := PSMFKindAvc;
      S.Width := Data[O + 12] * 16;
      S.Height := Data[O + 13] * 16;
    end
    else if S.StreamId = $BD then
    begin
      if (S.PrivateId and $F0) = $40 then
        S.Kind := PSMFKindPcm
      else
        S.Kind := PSMFKindAtrac;
      S.Channels := Data[O + 14];
      S.Frequency := Data[O + 15];
    end
    else
      S.Kind := PSMFKindData;
    S.EPMapOffset := PSMFBE32(@Data[O + 4]);
    S.EPMapCount := PSMFBE32(@Data[O + 8]);
    if S.Kind <= 3 then
    begin
      S.Number := Numbers[S.Kind];
      Inc(Numbers[S.Kind]);
    end;
    if (S.EPMapCount > 0) and (S.EPMapCount < $10000) and (Int64(S.EPMapOffset) + Int64(S.EPMapCount) * 10 <=
      Length(Data)) then
    begin
      SetLength(S.EP, S.EPMapCount);
      for var E := 0 to Integer(S.EPMapCount) - 1 do
      begin
        var P := PByte(@Data[S.EPMapOffset + Cardinal(E) * 10]);
        S.EP[E].Index := P[0];
        S.EP[E].PicOffset := P[1];
        S.EP[E].Pts := PSMFBE32(P + 2);
        S.EP[E].Offset := PSMFBE32(P + 6);
      end;
    end;
    Streams := Streams + [S];
  end;
  Valid := True;
  Result := 0;
end;

function TPSPPsmfHeader.Count(Kind: Integer): Integer;
begin
  Result := 0;
  for var S in Streams do
    if S.Kind = Kind then
      Inc(Result);
end;

function TPSPPsmfHeader.Find(Kind, Number: Integer): Integer;
begin
  for var I := 0 to High(Streams) do
    if (Streams[I].Kind = Kind) and (Streams[I].Number = Number) then
      Exit(I);
  Result := -1;
end;

{ TPSPEsQueue }

constructor TPSPEsQueue.Create;
begin
  inherited Create;
  Marks := TList<TPSPTimeMark>.Create;
  Sizes := TQueue<Cardinal>.Create;
end;

destructor TPSPEsQueue.Destroy;
begin
  Marks.Free;
  Sizes.Free;
  inherited;
end;

procedure TPSPEsQueue.Clear;
begin
  FStart := 0;
  FLength := 0;
  TotalIn := 0;
  TotalOut := 0;
  Marks.Clear;
  Sizes.Clear;
  AudioSkip := 0;
  AudioStarted := False;
end;

procedure TPSPEsQueue.Discard;
begin
  Drop(FLength);
  Marks.Clear;
  Sizes.Clear;
  AudioSkip := 0;
  AudioStarted := False;
end;

procedure TPSPEsQueue.Append(const Src; Count: Integer);
begin
  if Count <= 0 then
    Exit;
  if FStart + FLength + Count > System.Length(FData) then
  begin
    if FStart > 0 then
    begin
      if FLength > 0 then
        Move(FData[FStart], FData[0], FLength);
      FStart := 0;
    end;
    if FLength + Count > System.Length(FData) then
      SetLength(FData, (FLength + Count) * 2 + 4096);
  end;
  Move(Src, FData[FStart + FLength], Count);
  Inc(FLength, Count);
  Inc(TotalIn, Count);
end;

function TPSPEsQueue.Peek(Offset: Integer): Byte;
begin
  Result := FData[FStart + Offset];
end;

procedure TPSPEsQueue.Take(Count: Integer; out Dest: TBytes);
begin
  if Count > FLength then
    Count := FLength;
  SetLength(Dest, Count);
  if Count > 0 then
    Move(FData[FStart], Dest[0], Count);
  Drop(Count);
end;

procedure TPSPEsQueue.Drop(Count: Integer);
begin
  if Count > FLength then
    Count := FLength;
  Inc(FStart, Count);
  Dec(FLength, Count);
  Inc(TotalOut, Count);
  if FLength = 0 then
    FStart := 0;
end;

{ TPSPPsDemux }

constructor TPSPPsDemux.Create;
begin
  inherited Create;
  FQueues := TObjectList<TPSPEsQueue>.Create(True);
  FPending := TQueue<TPSPPackInfo>.Create;
end;

destructor TPSPPsDemux.Destroy;
begin
  FPending.Free;
  FQueues.Free;
  inherited;
end;

procedure TPSPPsDemux.Reset;
begin
  for var Q in FQueues do
    Q.Clear;
  FPending.Clear;
  FParsed := 0;
end;

function TPSPPsDemux.AddStream(Kind: Integer; StreamId, PrivateId: Byte): TPSPEsQueue;
begin
  Result := TPSPEsQueue.Create;
  Result.Kind := Kind;
  Result.StreamId := StreamId;
  Result.PrivateId := PrivateId;
  Result.Active := True;
  FQueues.Add(Result);
end;

procedure TPSPPsDemux.RemoveStream(Q: TPSPEsQueue);
begin
  var Items := FPending.ToArray;
  FPending.Clear;
  for var I in Items do
  begin
    var X := I;
    for var K := 0 to X.Count - 1 do
      if X.Queue[K] = Q then
        X.Queue[K] := nil;
    FPending.Enqueue(X);
  end;
  FQueues.Remove(Q);
end;

function TPSPPsDemux.QueueFor(StreamId, PrivateId: Byte): TPSPEsQueue;
begin
  for var Q in FQueues do
    if Q.Active and (Q.StreamId = StreamId) and ((StreamId <> $BD) or (Q.PrivateId = PrivateId)) then
      Exit(Q);
  Result := nil;
end;

procedure TPSPPsDemux.ParseTable(const P: PByte; Len: Integer);
begin
  // 01 <stream id> ... u16 size of the rest, u16 count, then u16 flags + u16 size per unit.
  if Len < 18 then
    Exit;
  var Q := QueueFor(P[1], 0);
  if (Q = nil) or (Q.Kind <> PSMFKindAvc) then
    Exit;
  var N := Integer(PSMFBE16(P + 16));
  for var I := 0 to N - 1 do
  begin
    var O := 18 + I * 4;
    if O + 4 > Len then
      Break;
    Q.Sizes.Enqueue((PSMFBE16(P + O) shl 16) or PSMFBE16(P + O + 2));
  end;
end;

procedure TPSPPsDemux.ParsePes(const P: PByte; Len: Integer; StreamId: Byte);
begin
  // P points after the 6-byte PES start, Len bytes of PES data.
  if Len < 3 then
    Exit;
  var Flags := P[1];
  var HeaderLen := P[2];
  var Pts := PSMFNoTimestamp;
  var Dts := PSMFNoTimestamp;
  if ((Flags and $80) <> 0) and (HeaderLen >= 5) then
  begin
    Pts := PSMFReadTimestamp(P + 3);
    Dts := Pts;
    if ((Flags and $40) <> 0) and (HeaderLen >= 10) then
      Dts := PSMFReadTimestamp(P + 8);
  end;
  var Pay := 3 + HeaderLen;
  if Pay > Len then
    Exit;
  var Q: TPSPEsQueue;
  var First := 0;
  if StreamId = $BD then
  begin
    if Pay + 4 > Len then
      Exit;
    Q := QueueFor($BD, P[Pay]);
    if Q = nil then
      Exit;
    // Sub-stream id, then the offset of the first frame header in this payload.
    First := Integer(PSMFBE16(P + Pay + 2));
    Inc(Pay, 4);
    if not Q.AudioStarted then
    begin
      // Data before the first frame header belongs to a frame we never saw.
      Q.AudioStarted := True;
      Q.AudioSkip := First;
    end;
  end
  else
  begin
    Q := QueueFor(StreamId, 0);
    if Q = nil then
      Exit;
  end;
  if (Pts <> PSMFNoTimestamp) and (First < Len - Pay) then
  begin
    var M: TPSPTimeMark;
    M.EsOffset := Q.TotalIn + First;
    M.Pts := Pts;
    M.Dts := Dts;
    Q.Marks.Add(M);
  end;
  Q.Append(P[Pay], Len - Pay);
  for var K := 0 to FPack.Count - 1 do
    if FPack.Queue[K] = Q then
    begin
      FPack.EsEnd[K] := Q.TotalIn;
      Exit;
    end;
  if FPack.Count <= High(FPack.Queue) then
  begin
    FPack.Queue[FPack.Count] := Q;
    FPack.EsEnd[FPack.Count] := Q.TotalIn;
    Inc(FPack.Count);
  end;
end;

procedure TPSPPsDemux.FeedPack(const Pack: PByte);
begin
  Inc(FParsed);
  FPack := Default(TPSPPackInfo);
  var P := 0;
  while P + 4 <= PSMFPacketSize do
  begin
    if (Pack[P] <> 0) or (Pack[P + 1] <> 0) or (Pack[P + 2] <> 1) then
      Break;
    var Id := Pack[P + 3];
    if Id = $BA then
    begin
      if P + 14 > PSMFPacketSize then
        Break;
      Inc(P, 14 + (Pack[P + 13] and 7));
      Continue;
    end;
    if P + 6 > PSMFPacketSize then
      Break;
    var Len := Integer(PSMFBE16(Pack + P + 4));
    var Avail := PSMFPacketSize - (P + 6);
    if Len > Avail then
      Len := Avail;
    case Id of
      $BF:
        ParseTable(Pack + P + 6, Len);
      $BD, $E0..$EF:
        ParsePes(Pack + P + 6, Len, Id);
    end;
    Inc(P, 6 + Len);
  end;
  // A pack without data for a registered stream is done as soon as the ones before are.
  FPending.Enqueue(FPack);
end;

function TPSPPsDemux.Held: Integer;
begin
  Result := FPending.Count;
end;

function TPSPPsDemux.TakeFreed: Integer;
begin
  Result := 0;
  while FPending.Count > 0 do
  begin
    var I := FPending.Peek;
    var Done := True;
    for var K := 0 to I.Count - 1 do
      if (I.Queue[K] <> nil) and (I.Queue[K].TotalOut < I.EsEnd[K]) then
        Done := False;
    if not Done then
      Break;
    FPending.Dequeue;
    Inc(Result);
  end;
end;

procedure TPSPPsDemux.TakeMarks(Q: TPSPEsQueue; Start, Size: Int64; out Pts, Dts: Int64);
begin
  Pts := PSMFNoTimestamp;
  Dts := PSMFNoTimestamp;
  while (Q.Marks.Count > 0) and (Q.Marks[0].EsOffset < Start + Size) do
  begin
    // Only a unit that begins a PES payload gets that PES's timestamps.
    if Q.Marks[0].EsOffset = Start then
    begin
      Pts := Q.Marks[0].Pts;
      Dts := Q.Marks[0].Dts;
    end;
    Q.Marks.Delete(0);
  end;
end;

function TPSPPsDemux.VideoAuSize(Q: TPSPEsQueue): Integer;
begin
  if Q.Sizes.Count > 0 then
    // The table word combines a 23-bit length with flags above it. In
    // particular, an IDR may exceed 64 KB; bit 23 is the AU attribute.
    Exit(Integer(Q.Sizes.Peek and $7FFFFF));
  // No table: up to the next access unit delimiter.
  var N := Q.Length;
  var I := 4;
  while I + 3 < N do
  begin
    if (Q.Peek(I) = 0) and (Q.Peek(I + 1) = 0) and (Q.Peek(I + 2) = 1) and ((Q.Peek(I + 3) and $1F) = 9) then
    begin
      if Q.Peek(I - 1) = 0 then
        Exit(I - 1);
      Exit(I);
    end;
    Inc(I);
  end;
  Result := -1;
end;

procedure TPSPPsDemux.SkipAudioJunk(Q: TPSPEsQueue);
begin
  if Q.AudioSkip > 0 then
  begin
    var N := Q.AudioSkip;
    if N > Q.Length then
      N := Q.Length;
    Q.Drop(N);
    Dec(Q.AudioSkip, N);
  end;
end;

function TPSPPsDemux.AudioAuSize(Q: TPSPEsQueue): Integer;
begin
  SkipAudioJunk(Q);
  if Q.AudioSkip > 0 then
    Exit(-1);
  if Q.Kind = PSMFKindPcm then
    Exit(-1);
  if Q.Length < 8 then
    Exit(-1);
  if (Q.Peek(0) <> $0F) or (Q.Peek(1) <> $D0) then
    Exit(-1);
  Result := PSMFAtracFrameSize(Q.Peek(2), Q.Peek(3));
end;

function TPSPPsDemux.HasAu(Q: TPSPEsQueue; Final: Boolean): Boolean;
begin
  var Size: Integer;
  if Q.Kind = PSMFKindAvc then
    Size := VideoAuSize(Q)
  else
    Size := AudioAuSize(Q);
  if (Size < 0) and Final and (Q.Length > 0) then
    Size := Q.Length;
  Result := (Size > 0) and (Size <= Q.Length);
end;

function TPSPPsDemux.NextAu(Q: TPSPEsQueue; out Au: TPSPAccessUnit; Final: Boolean): Boolean;
begin
  Au := Default(TPSPAccessUnit);
  Au.Pts := PSMFNoTimestamp;
  Au.Dts := PSMFNoTimestamp;
  var Size: Integer;
  if Q.Kind = PSMFKindAvc then
    Size := VideoAuSize(Q)
  else
    Size := AudioAuSize(Q);
  if (Size < 0) and Final and (Q.Length > 0) then
    Size := Q.Length;
  if (Size <= 0) or (Size > Q.Length) then
    Exit(False);
  Au.Flags := $80;
  if (Q.Kind = PSMFKindAvc) and (Q.Sizes.Count > 0) then
    Au.Flags := Q.Sizes.Dequeue shr 16;
  TakeMarks(Q, Q.TotalOut, Size, Au.Pts, Au.Dts);
  Q.Take(Size, Au.Data);
  Result := True;
end;

end.
