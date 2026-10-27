unit PSP.MpegStream;

interface

uses
  System.SysUtils, System.Generics.Collections, Video.AVC.Types;

type
  // Incremental MPEG-2 program stream parser. Incomplete PES and NAL units are
  // retained across arbitrary ring-buffer packet boundaries.
  TPSPMpegStream = class
  private
    FInput, FVideo, FAccess, FAudio: TBytes;
    FAudioPTS: Int64;
    FAudioRemainder: Integer;
    FQueuedBytes: Integer;
    FAudioPackets: TQueue<TMediaPacket>;
    FHasSlice: Boolean;
    FPTS, FNextPTS: Int64;
    FVideoPackets: TQueue<TMediaPacket>;
    FVideoLengths, FVideoAttributes: TQueue<Cardinal>;
    FLengthMode: Boolean;
    FLastVideoAttribute: Cardinal;
    procedure VideoLengths(const Data: TBytes);
    procedure LengthVideoData(const Data: TBytes; PTS: Int64);
    procedure AudioData(const Data: TBytes; PTS: Int64);
    procedure VideoData(const Data: TBytes; PTS: Int64);
    procedure CompleteNAL(const Data: TBytes);
    procedure CompleteAccess;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Feed(const Data: TBytes);
    procedure Flush;
    function RetainedBytes: Integer;
    function RingRetainedBytes: Integer;
    function ReceiveVideo(out Packet: TMediaPacket): Boolean;
    function ReceiveAudio(out Packet: TMediaPacket): Boolean;
    property LastVideoAttribute: Cardinal read FLastVideoAttribute;
  end;

implementation

constructor TPSPMpegStream.Create;
begin
  inherited;
  FVideoPackets := TQueue<TMediaPacket>.Create;
  FVideoLengths := TQueue<Cardinal>.Create;
  FVideoAttributes := TQueue<Cardinal>.Create;
  FAudioPackets := TQueue<TMediaPacket>.Create;
  FAudioPTS := -1;
  FPTS := -1;
  FNextPTS := 0
end;

destructor TPSPMpegStream.Destroy;
begin
  FVideoPackets.Free;
  FVideoLengths.Free;
  FVideoAttributes.Free;
  FAudioPackets.Free;
  inherited
end;

function TimeStamp(const Data: TBytes; P: Integer): Int64;
begin
  if (P < 0) or (P + 5 > Length(Data)) then
    raise EPlayerFormat.Create('Truncated MPEG timestamp');
  if (Data[P] and 1 = 0) or (Data[P + 2] and 1 = 0) or (Data[P + 4] and 1 = 0) then
    raise EPlayerFormat.Create('Invalid MPEG timestamp markers');
  Result := (Int64(Data[P] and 14) shl 29) or (Int64(Data[P + 1]) shl 22) or
    (Int64(Data[P + 2] shr 1) shl 15) or (Data[P + 3] shl 7) or (Data[P + 4] shr 1);
end;

procedure TPSPMpegStream.CompleteAccess;
begin
  if not FHasSlice then
    Exit;
  if FVideoPackets.Count >= 8192 then
    raise EPlayerFormat.Create('PSP MPEG video queue overflow');
  var Packet := Default(TMediaPacket);
  Packet.Data := FAccess;
  if FPTS < 0 then
    FPTS := FNextPTS;
  Packet.PTS := FPTS;
  Packet.DTS := FPTS;
  Packet.Duration := 3003;
  FNextPTS := FPTS + 3003;
  Inc(FQueuedBytes, Length(Packet.Data));
  FVideoPackets.Enqueue(Packet);
  FVideoAttributes.Enqueue(1);
  FAccess := nil;
  FHasSlice := False;
  FPTS := -1;
end;

procedure TPSPMpegStream.CompleteNAL(const Data: TBytes);
begin
  if Length(Data) = 0 then
    Exit;
  var Kind := Data[0] and 31;
  if (Kind = 9) and FHasSlice then
    CompleteAccess;
  var Old := Length(FAccess);
  if Length(Data) > 4 * 1024 * 1024 - Old then
    raise EPlayerFormat.Create('PSP MPEG access unit too large');
  SetLength(FAccess, Old + 4 + Length(Data));
  FAccess[Old] := 0;
  FAccess[Old + 1] := 0;
  FAccess[Old + 2] := 0;
  FAccess[Old + 3] := 1;
  Move(Data[0], FAccess[Old + 4], Length(Data));
  if Kind in [1, 5] then
    FHasSlice := True;
end;

procedure TPSPMpegStream.VideoData(const Data: TBytes; PTS: Int64);
begin
  if FLengthMode then
  begin
    LengthVideoData(Data, PTS);
    Exit
  end;
  if (FPTS < 0) and (PTS >= 0) then
    FPTS := PTS;
  var Old := Length(FVideo);
  if Old + Length(Data) > 8 * 1024 * 1024 then
    raise EPlayerFormat.Create('PSP MPEG NAL buffer overflow');
  FVideo := FVideo + Data;
  var Start := -1;
  var Consumed := 0;
  var P := 0;
  while P + 3 <= Length(FVideo) do
  begin
    if (FVideo[P] = 0) and (FVideo[P + 1] = 0) and (FVideo[P + 2] = 1) then
    begin
      if Start >= 0 then
      begin
        var Last := P;
        while (Last > Start) and (FVideo[Last - 1] = 0) do
          Dec(Last);
        CompleteNAL(Copy(FVideo, Start, Last - Start));
      end;
      Consumed := P;
      Start := P + 3;
      Inc(P, 3);
    end
    else
      Inc(P);
  end;
  if Consumed > 0 then
    FVideo := Copy(FVideo, Consumed, Length(FVideo) - Consumed);
end;

procedure TPSPMpegStream.VideoLengths(const Data: TBytes);
begin
  // PSMF AVC reference-picture stream (private_stream_2, 01 E0 00).
  // Each descriptor carries the exact Annex-B AU length and firmware attributes.
  // This releases the final AU without inventing EOF at a temporary ring gap.
  if (Length(Data)<18) or (Data[0]<>1) or (Data[1]<>$E0) or (Data[2]<>0) then Exit;
  if not FLengthMode and ((Length(FVideo)<>0) or (Length(FAccess)<>0)) then Exit;
  var Count:=Integer(Data[17]);
  if Length(Data)<18+Count*4 then raise EPlayerFormat.Create('Truncated PSMF AVC length table');
  if FVideoLengths.Count+Count>8192 then raise EPlayerFormat.Create('PSMF AVC length queue overflow');
  for var I:=0 to Count-1 do
  begin
    var P:=18+I*4;
    var Descriptor:Cardinal:=(Cardinal(Data[P]) shl 24) or (Cardinal(Data[P+1]) shl 16) or (Cardinal(Data[P+2]) shl 8) or Data[P+3];
    if Descriptor and $1FFFFF=0 then raise EPlayerFormat.Create('Empty PSMF AVC access unit');
    FVideoLengths.Enqueue(Descriptor);
  end;
  FLengthMode:=True;
  LengthVideoData(nil,-1);
end;

procedure TPSPMpegStream.LengthVideoData(const Data: TBytes; PTS: Int64);
begin
  if (Length(FVideo)=0) and (PTS>=0) then FPTS:=PTS;
  if FPTS<0 then FPTS:=FNextPTS;
  if Length(Data)>8*1024*1024-Length(FVideo) then raise EPlayerFormat.Create('PSMF AVC buffer overflow');
  FVideo:=FVideo+Data;
  var Consumed:=0;
  while FVideoLengths.Count<>0 do
  begin
    var Descriptor:=FVideoLengths.Peek;
    var Size:=Integer(Descriptor and $1FFFFF);
    if Size>Length(FVideo)-Consumed then Break;
    if FVideoPackets.Count>=8192 then raise EPlayerFormat.Create('PSP MPEG video queue overflow');
    FVideoLengths.Dequeue;
    var Packet:=Default(TMediaPacket);
    Packet.Data:=Copy(FVideo,Consumed,Size);
    Packet.PTS:=FPTS;Packet.DTS:=FPTS;Packet.Duration:=3003;
    FVideoPackets.Enqueue(Packet);
    FVideoAttributes.Enqueue(((Descriptor shr 23) and 1) or (((Descriptor shr 24) and 15) shl 1));
    Inc(FQueuedBytes,Size);Inc(Consumed,Size);
    FNextPTS:=FPTS+3003;FPTS:=FNextPTS;
  end;
  if Consumed<>0 then FVideo:=Copy(FVideo,Consumed,Length(FVideo)-Consumed);
end;

procedure TPSPMpegStream.Feed(const Data: TBytes);
begin
  if Length(Data) > 16 * 1024 * 1024 - Length(FInput) then
    raise EPlayerFormat.Create('PSP MPEG input overflow');
  FInput := FInput + Data;
  var P := 0;
  while P + 6 <= Length(FInput) do
  begin
    if (FInput[P] <> 0) or (FInput[P + 1] <> 0) or (FInput[P + 2] <> 1) then
    begin
      Inc(P);
      Continue
    end;
    var Code := FInput[P + 3];
    if Code = $B9 then
    begin
      Inc(P, 4);
      Continue
    end;
    if Code = $BA then
    begin
      if P + 14 > Length(FInput) then
        Break;
      var Size := 14 + (FInput[P + 13] and 7);
      if P + Size > Length(FInput) then
        Break;
      Inc(P, Size);
      Continue;
    end;
    var Size := 6 + (Integer(FInput[P + 4]) shl 8) + FInput[P + 5];
    if P + Size > Length(FInput) then
      Break;
    if Code=$BF then VideoLengths(Copy(FInput,P+6,Size-6))
    else if Code in [$E0..$EF, $BD] then
    begin
      if Size < 9 then
        raise EPlayerFormat.Create('Short MPEG PES header');
      var Header := 9 + FInput[P + 8];
      if Header > Size then
        raise EPlayerFormat.Create('Invalid MPEG PES header size');
      var PTS: Int64 := -1;
      if FInput[P + 7] and $80 <> 0 then
      begin
        if Header < 14 then
          raise EPlayerFormat.Create('Short MPEG PES PTS');
        PTS := TimeStamp(FInput, P + 9);
      end;
      if Code in [$E0..$EF] then
        VideoData(Copy(FInput, P + Header, Size - Header), PTS)
      else if Header + 4 <= Size then
      begin
        var SubHeader := 4;
        if FInput[P + Header] in [$B0..$BF] then
          SubHeader := 5;
        if Header + SubHeader <= Size then
          AudioData(Copy(FInput, P + Header + SubHeader, Size - Header - SubHeader), PTS);
      end;
    end;
    Inc(P, Size);
  end;
  if P > 0 then
    FInput := Copy(FInput, P, Length(FInput) - P);
end;

procedure TPSPMpegStream.AudioData(const Data: TBytes; PTS: Int64);
begin
  if FAudioPTS < 0 then
    FAudioPTS := PTS;
  if Length(FAudio) + Length(Data) > 4 * 1024 * 1024 then
    raise EPlayerFormat.Create('PSP MPEG audio buffer overflow');
  FAudio := FAudio + Data;
  var P := 0;
  while P + 8 <= Length(FAudio) do
  begin
    if (FAudio[P] <> $0F) or (FAudio[P + 1] <> $D0) then
    begin
      Inc(P);
      Continue
    end;
    var Size := (((FAudio[P + 2] and 3) shl 8) + Integer(FAudio[P + 3])) * 8 + 16;
    if P + Size > Length(FAudio) then
      Break;
    if FAudioPackets.Count >= 8192 then
      raise EPlayerFormat.Create('PSP MPEG audio queue overflow');
    var Packet := Default(TMediaPacket);
    Packet.Data := Copy(FAudio, P + 8, Size - 8);
    Packet.PTS := FAudioPTS;
    Packet.DTS := -1;
    var Clock := 2048 * 90000 + FAudioRemainder;
    Packet.Duration := Clock div 44100;
    FAudioRemainder := Clock mod 44100;
    Packet.TrackIndex := 2;
    if (FAudio[P + 2] shr 2) and 7 = 1 then
      Packet.TrackIndex := 1;
    Inc(FQueuedBytes, Length(Packet.Data));
    FAudioPackets.Enqueue(Packet);
    Inc(FAudioPTS, Packet.Duration);
    Inc(P, Size);
  end;
  if P > 0 then
    FAudio := Copy(FAudio, P, Length(FAudio) - P);
end;

function TPSPMpegStream.ReceiveAudio(out Packet: TMediaPacket): Boolean;
begin
  Result := FAudioPackets.Count > 0;
  if Result then
  begin
    Packet := FAudioPackets.Dequeue;
    Dec(FQueuedBytes, Length(Packet.Data))
  end
  else
    Packet := Default(TMediaPacket);
end;

function TPSPMpegStream.RetainedBytes: Integer;
begin
  Result := FQueuedBytes + Length(FInput) + Length(FVideo) + Length(FAccess) + Length(FAudio)
end;

function TPSPMpegStream.RingRetainedBytes: Integer;
begin
  // Completed AUs wait for their consumer, while a partial PES still belongs
  // to demux input. Elementary fragments have already moved into ES assembly
  // storage and must not pin ring packets after an underflowing Get*Au call.
  Result:=FQueuedBytes+Length(FInput);
end;

procedure TPSPMpegStream.Flush;
begin
  if FLengthMode then
  begin
    LengthVideoData(nil,-1);
    Exit
  end;
  VideoData(nil, -1);
  var Start := -1;
  for var P := 0 to Length(FVideo) - 3 do
    if (FVideo[P] = 0) and (FVideo[P + 1] = 0) and (FVideo[P + 2] = 1) then
    begin
      Start := P + 3;
      Break
    end;
  if Start >= 0 then
    CompleteNAL(Copy(FVideo, Start, Length(FVideo) - Start));
  FVideo := nil;
  CompleteAccess;
end;

function TPSPMpegStream.ReceiveVideo(out Packet: TMediaPacket): Boolean;
begin
  Result := FVideoPackets.Count > 0;
  if Result then
  begin
    Packet := FVideoPackets.Dequeue;
    FLastVideoAttribute := FVideoAttributes.Dequeue;
    Dec(FQueuedBytes, Length(Packet.Data))
  end
  else
    Packet := Default(TMediaPacket);
end;

end.

