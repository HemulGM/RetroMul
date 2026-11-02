unit PSP.Mp4;

// sceMp4: MP4 movies for the ME. The library reads the file through the
// guest's tell/seek/read callbacks, keeps the sample tables and hands out the
// video samples as Annex B access units in the AVC ES buffer, with the track's
// parameter sets in front of every key frame.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Generics.Collections, PSP.Types, PSP.Memory, PSP.CPU,
  PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service, PSP.State.Action;

type
  TPSPMp4Sample = record
    Offset: Int64;
    Size: Cardinal;
    Dts, Cts: Int64;
    Key: Boolean;
  end;

  TPSPMp4Track = class
  public
    Handler: string;
    TimeScale: Cardinal;
    Duration: Int64;
    Width, Height: Integer;
    NalLength: Integer;
    ParamSets: TBytes;
    Samples: TArray<TPSPMp4Sample>;
  end;

  TPSPMp4File = class
  public
    Address: Cardinal;
    Data: TBytes;
    Tracks: TObjectList<TPSPMp4Track>;
    constructor Create;
    destructor Destroy; override;
    procedure Parse;
  end;

  TPSPMp4Reg = class
  public
    Address: Cardinal;
    Mp4: TPSPMp4File;
    Track: TPSPMp4Track;
    Capacity, MaxSampleSize: Integer;
    Next, Buffered: Integer;
  end;

  TPSPMp4 = class(TPSPService)
  private
    FFiles: TObjectList<TPSPMp4File>;
    FRegs: TObjectList<TPSPMp4Reg>;
    function FileAt(Address: Cardinal): TPSPMp4File;
    function RegAt(Address: Cardinal): TPSPMp4Reg;
    procedure ReadStep(F: TPSPMp4File; Param, ReadFn, Buf, BufSize: Cardinal; Total, Done: Int64; GP: Cardinal);
    procedure StateRead(Action: TPSPStateAction; Value: Cardinal);
    procedure StateSeekEnd(Action: TPSPStateAction; Value: Cardinal);
    procedure StateSeekStart(Action: TPSPStateAction; Value: Cardinal);
    procedure hInit;
    procedure hFinish;
    procedure hCreate;
    procedure hDelete;
    procedure hGetMovieInfo;
    procedure hGetNumberOfSpecificTrack;
    procedure hRegistTrack;
    procedure hUnregistTrack;
    procedure hQueryMemSize;
    procedure hConstruct;
    procedure hDestruct;
    procedure hGetAvcTrackInfoData;
    procedure hFlush;
    procedure hPutSampleNum;
    procedure hAvailableSize;
    procedure hPut;
    procedure hGetAvcAu;
    procedure hZero;
  public
    constructor Create(System: TPSPSystem); override;
    destructor Destroy; override;
    procedure Reset; override;
    procedure Register; override;
  end;

implementation

uses
  System.Math;

const
  LibMp4 = 'sceMp4';
  ERROR_MP4_NO_MORE_DATA = Cardinal($80618001);
  ERROR_MP4_INVALID_VALUE = Cardinal($806101FE);

function BE32(const D: TBytes; P: Int64): Cardinal;
begin
  if (P < 0) or (P + 4 > Length(D)) then
    Exit(0);
  Result := (Cardinal(D[P]) shl 24) or (Cardinal(D[P + 1]) shl 16) or (Cardinal(D[P + 2]) shl 8) or D[P + 3];
end;

function BE16(const D: TBytes; P: Int64): Cardinal;
begin
  if (P < 0) or (P + 2 > Length(D)) then
    Exit(0);
  Result := (Cardinal(D[P]) shl 8) or D[P + 1];
end;

function BE64(const D: TBytes; P: Int64): Int64;
begin
  Result := (Int64(BE32(D, P)) shl 32) or BE32(D, P + 4);
end;

{ TPSPMp4File }

constructor TPSPMp4File.Create;
begin
  inherited Create;
  Tracks := TObjectList<TPSPMp4Track>.Create(True);
end;

destructor TPSPMp4File.Destroy;
begin
  Tracks.Free;
  inherited;
end;

procedure TPSPMp4File.Parse;
var
  T: TPSPMp4Track;
  Sizes: TArray<Cardinal>;
  Chunks: TArray<Int64>;
  StscFirst, StscCount: TArray<Cardinal>;
  SttsCount, SttsDelta: TArray<Cardinal>;
  CttsCount: TArray<Cardinal>;
  CttsOffset: TArray<Integer>;
  Keys: TArray<Cardinal>;
  HasKeys: Boolean;

  procedure FinishTrack;
  begin
    if T = nil then
      Exit;
    var N := Length(Sizes);
    SetLength(T.Samples, N);
    var S := 0;
    for var C := 0 to High(Chunks) do
    begin
      var PerChunk: Cardinal := 0;
      for var E := 0 to High(StscFirst) do
        if StscFirst[E] <= Cardinal(C + 1) then
          PerChunk := StscCount[E];
      var Off := Chunks[C];
      for var K := 1 to Integer(PerChunk) do
      begin
        if S >= N then
          Break;
        T.Samples[S].Offset := Off;
        T.Samples[S].Size := Sizes[S];
        Inc(Off, Sizes[S]);
        Inc(S);
      end;
    end;
    var Dts: Int64 := 0;
    S := 0;
    for var E := 0 to High(SttsCount) do
      for var K := 1 to Integer(SttsCount[E]) do
      begin
        if S < N then
        begin
          T.Samples[S].Dts := Dts;
          T.Samples[S].Cts := Dts;
        end;
        Inc(Dts, SttsDelta[E]);
        Inc(S);
      end;
    S := 0;
    for var E := 0 to High(CttsCount) do
      for var K := 1 to Integer(CttsCount[E]) do
      begin
        if S < N then
          T.Samples[S].Cts := T.Samples[S].Dts + CttsOffset[E];
        Inc(S);
      end;
    for var I := 0 to N - 1 do
      T.Samples[I].Key := not HasKeys;
    for var K in Keys do
      if (K >= 1) and (K <= Cardinal(N)) then
        T.Samples[K - 1].Key := True;
    Tracks.Add(T);
    T := nil;
  end;

  procedure Boxes(Start, Stop: Int64);
  begin
    var P := Start;
    while P + 8 <= Stop do
    begin
      var Size := Int64(BE32(Data, P));
      var Kind := TEncoding.ANSI.GetString(Data, P + 4, 4);
      var Hdr := 8;
      if Size = 1 then
      begin
        Size := BE64(Data, P + 8);
        Hdr := 16;
      end
      else if Size = 0 then
        Size := Stop - P;
      if (Size < Hdr) or (P + Size > Stop) then
        Break;
      var B := P + Hdr;
      var E := P + Size;
      if Kind = 'trak' then
      begin
        FinishTrack;
        T := TPSPMp4Track.Create;
        T.NalLength := 4;
        Sizes := nil;
        Chunks := nil;
        StscFirst := nil;
        StscCount := nil;
        SttsCount := nil;
        SttsDelta := nil;
        CttsCount := nil;
        CttsOffset := nil;
        Keys := nil;
        HasKeys := False;
        Boxes(B, E);
        FinishTrack;
      end
      else if (Kind = 'moov') or (Kind = 'mdia') or (Kind = 'minf') or (Kind = 'stbl') then
        Boxes(B, E)
      else if T <> nil then
      begin
        if Kind = 'mdhd' then
        begin
          if Data[B] = 1 then
          begin
            T.TimeScale := BE32(Data, B + 20);
            T.Duration := BE64(Data, B + 24);
          end
          else
          begin
            T.TimeScale := BE32(Data, B + 12);
            T.Duration := BE32(Data, B + 16);
          end;
        end
        else if Kind = 'hdlr' then
          T.Handler := TEncoding.ANSI.GetString(Data, B + 8, 4)
        else if Kind = 'stsd' then
          Boxes(B + 8, E)
        else if Kind = 'avc1' then
        begin
          T.Width := BE16(Data, B + 24);
          T.Height := BE16(Data, B + 26);
          Boxes(B + 78, E);
        end
        else if Kind = 'avcC' then
        begin
          T.NalLength := (Data[B + 4] and 3) + 1;
          var Q := B + 5;
          var Ps: TBytes := nil;
          for var Pass := 0 to 1 do
          begin
            var Count := Data[Q];
            if Pass = 0 then
              Count := Count and $1F;
            Inc(Q);
            for var I := 1 to Count do
            begin
              var L := BE16(Data, Q);
              Inc(Q, 2);
              Ps := Ps + [0, 0, 0, 1] + Copy(Data, Q, L);
              Inc(Q, L);
            end;
          end;
          T.ParamSets := Ps;
        end
        else if Kind = 'stsz' then
        begin
          var Fixed := BE32(Data, B + 4);
          var N := BE32(Data, B + 8);
          SetLength(Sizes, N);
          for var I := 0 to Integer(N) - 1 do
            if Fixed <> 0 then
              Sizes[I] := Fixed
            else
              Sizes[I] := BE32(Data, B + 12 + I * 4);
        end
        else if (Kind = 'stco') or (Kind = 'co64') then
        begin
          var N := BE32(Data, B + 4);
          SetLength(Chunks, N);
          for var I := 0 to Integer(N) - 1 do
            if Kind = 'stco' then
              Chunks[I] := BE32(Data, B + 8 + I * 4)
            else
              Chunks[I] := BE64(Data, B + 8 + I * 8);
        end
        else if Kind = 'stsc' then
        begin
          var N := BE32(Data, B + 4);
          SetLength(StscFirst, N);
          SetLength(StscCount, N);
          for var I := 0 to Integer(N) - 1 do
          begin
            StscFirst[I] := BE32(Data, B + 8 + I * 12);
            StscCount[I] := BE32(Data, B + 12 + I * 12);
          end;
        end
        else if Kind = 'stts' then
        begin
          var N := BE32(Data, B + 4);
          SetLength(SttsCount, N);
          SetLength(SttsDelta, N);
          for var I := 0 to Integer(N) - 1 do
          begin
            SttsCount[I] := BE32(Data, B + 8 + I * 8);
            SttsDelta[I] := BE32(Data, B + 12 + I * 8);
          end;
        end
        else if Kind = 'ctts' then
        begin
          var N := BE32(Data, B + 4);
          SetLength(CttsCount, N);
          SetLength(CttsOffset, N);
          for var I := 0 to Integer(N) - 1 do
          begin
            CttsCount[I] := BE32(Data, B + 8 + I * 8);
            CttsOffset[I] := Integer(BE32(Data, B + 12 + I * 8));
          end;
        end
        else if Kind = 'stss' then
        begin
          HasKeys := True;
          var N := BE32(Data, B + 4);
          SetLength(Keys, N);
          for var I := 0 to Integer(N) - 1 do
            Keys[I] := BE32(Data, B + 8 + I * 4);
        end;
      end;
      P := E;
    end;
  end;

begin
  T := nil;
  Tracks.Clear;
  try
    Boxes(0, Length(Data));
    FinishTrack;
  except
    // A damaged file keeps the tracks read before the damage.
    on E: Exception do
      FreeAndNil(T);
  end;
end;

{ TPSPMp4 }

constructor TPSPMp4.Create(System: TPSPSystem);
begin
  inherited Create(System);
  FFiles := TObjectList<TPSPMp4File>.Create(True);
  FRegs := TObjectList<TPSPMp4Reg>.Create(True);
end;

destructor TPSPMp4.Destroy;
begin
  FRegs.Free;
  FFiles.Free;
  inherited;
end;

procedure TPSPMp4.Reset;
begin
  FRegs.Clear;
  FFiles.Clear;
end;

procedure TPSPMp4.Register;
begin
  var H := FHLE;
  H.Register(LibMp4, $68651CBC, 'sceMp4Init', hInit);
  H.Register(LibMp4, $9042B257, 'sceMp4Finish', hFinish);
  H.Register(LibMp4, $B1221EE7, 'sceMp4Create', hCreate);
  H.Register(LibMp4, $538C2057, 'sceMp4Delete', hDelete);
  H.Register(LibMp4, $7443AF1D, 'sceMp4GetMovieInfo', hGetMovieInfo);
  H.Register(LibMp4, $5EB65F26, 'sceMp4GetNumberOfSpecificTrack', hGetNumberOfSpecificTrack);
  H.Register(LibMp4, $7ADFD01C, 'sceMp4RegistTrack', hRegistTrack);
  H.Register(LibMp4, $6710FE77, 'sceMp4UnregistTrack', hUnregistTrack);
  H.Register(LibMp4, $BCA9389C, 'sceMp4TrackSampleBufQueryMemSize', hQueryMemSize);
  H.Register(LibMp4, $9C8F4FC1, 'sceMp4TrackSampleBufConstruct', hConstruct);
  H.Register(LibMp4, $01C76489, 'sceMp4TrackSampleBufDestruct', hDestruct);
  H.Register(LibMp4, $0F0187D2, 'sceMp4GetAvcTrackInfoData', hGetAvcTrackInfoData);
  H.Register(LibMp4, $9CE6F5CF, 'sceMp4GetAacTrackInfoData', hZero);
  H.Register(LibMp4, $496E8A65, 'sceMp4TrackSampleBufFlush', hFlush);
  H.Register(LibMp4, $D8250B75, 'sceMp4PutSampleNum', hPutSampleNum);
  H.Register(LibMp4, $8754ECB8, 'sceMp4TrackSampleBufAvailableSize', hAvailableSize);
  H.Register(LibMp4, $31BCD7E0, 'sceMp4TrackSampleBufPut', hPut);
  H.Register(LibMp4, $503A3CBA, 'sceMp4GetAvcAu', hGetAvcAu);
  H.Register(LibMp4, $5601A6F0, 'sceMp4GetAacAu', hZero);
  H.Register(LibMp4, $4ED4AB1E, 'sceMp4AacDecodeInitResource', hZero);
  H.Register(LibMp4, $10EE0D2C, 'sceMp4AacDecodeInit', hZero);
  H.Register(LibMp4, $7663CB5C, 'sceMp4AacDecode', hZero);
  H.Register(LibMp4, $5D72B333, 'sceMp4AacDecodeExit', hZero);
  H.Register(LibMp4, $7D332394, 'sceMp4AacDecodeTermResource', hZero);
end;

function TPSPMp4.FileAt(Address: Cardinal): TPSPMp4File;
begin
  for var F in FFiles do
    if F.Address = Address then
      Exit(F);
  Result := nil;
end;

function TPSPMp4.RegAt(Address: Cardinal): TPSPMp4Reg;
begin
  for var R in FRegs do
    if R.Address = Address then
      Exit(R);
  Result := nil;
end;

procedure TPSPMp4.hInit;
begin
  FHLE.Result(0);
end;

procedure TPSPMp4.hFinish;
begin
  FHLE.Result(0);
end;

procedure TPSPMp4.hZero;
begin
  FHLE.Result(0);
end;

procedure TPSPMp4.ReadStep(F: TPSPMp4File; Param, ReadFn, Buf, BufSize: Cardinal; Total, Done: Int64; GP: Cardinal);
begin
  if Done >= Total then
  begin
    SetLength(F.Data, Done);
    F.Parse;
    FHLE.CPU.Ctx.GPR[2] := 0;
    Exit;
  end;
  var Chunk := Min(Int64(BufSize), Total - Done);
  FKernel.CallGuest(ReadFn, [Param, Buf, Cardinal(Chunk)], nil, GP, TPSPStateAction.Create(StateRead, [F],
    [Param, ReadFn, Buf, BufSize, Total, Done, GP, Chunk]));
end;

procedure TPSPMp4.StateRead(Action: TPSPStateAction; Value: Cardinal);
begin
  var F := TPSPMp4File(Action.Obj(0));
  var Done := Action.Arg(5);
  var N := Integer(Value);
  if N <= 0 then
  begin
    SetLength(F.Data, Done);
    F.Parse;
    FHLE.CPU.Ctx.GPR[2] := 0;
    Exit;
  end;
  if N > Action.Arg(7) then
    N := Integer(Action.Arg(7));
  FMemory.ReadBytes(Cardinal(Action.Arg(2)), F.Data[Done], N);
  ReadStep(F, Cardinal(Action.Arg(0)), Cardinal(Action.Arg(1)), Cardinal(Action.Arg(2)), Cardinal(Action.Arg(3)),
    Action.Arg(4), Done + N, Cardinal(Action.Arg(6)));
end;

procedure TPSPMp4.hCreate;
begin
  var Mp4 := FHLE.Arg(0);
  var Cb := FHLE.Arg(1);
  var Buf := FHLE.Arg(2);
  var BufSize := FHLE.Arg(3);
  if (Cb = 0) or (Buf = 0) or (BufSize = 0) or (FKernel.Current = nil) then
  begin
    FHLE.Result(ERROR_MP4_INVALID_VALUE);
    Exit;
  end;
  var F := FileAt(Mp4);
  if F = nil then
  begin
    F := TPSPMp4File.Create;
    F.Address := Mp4;
    FFiles.Add(F);
  end;
  var Param := FMemory.Read32(Cb);
  var SeekFn := FMemory.Read32(Cb + 8);
  var ReadFn := FMemory.Read32(Cb + 12);
  var GP := FHLE.CPU.Ctx.GPR[28];
  FHLE.Result(0);
  // The file's size from seek(0, SEEK_END), then everything from the start.
  FKernel.CallGuest(SeekFn, [Param, 0, 0, 0, 2], nil, GP, TPSPStateAction.Create(StateSeekEnd, [F],
    [Param, SeekFn, ReadFn, Buf, BufSize, GP]));
end;

procedure TPSPMp4.StateSeekEnd(Action: TPSPStateAction; Value: Cardinal);
begin
  var Total := Int64(Value);
  if (Total <= 0) or (Total > 256 * 1024 * 1024) then
  begin
    FHLE.CPU.Ctx.GPR[2] := ERROR_MP4_INVALID_VALUE;
    Exit;
  end;
  var F := TPSPMp4File(Action.Obj(0));
  SetLength(F.Data, Total);
  Action.Values := Action.Values + [Total];
  Action.Handler := StateSeekStart;
  FKernel.CallGuest(Cardinal(Action.Arg(1)), [Cardinal(Action.Arg(0)), 0, 0, 0, 0], nil,
    Cardinal(Action.Arg(5)), Action);
end;

procedure TPSPMp4.StateSeekStart(Action: TPSPStateAction; Value: Cardinal);
begin
  ReadStep(TPSPMp4File(Action.Obj(0)), Cardinal(Action.Arg(0)), Cardinal(Action.Arg(2)), Cardinal(Action.Arg(3)),
    Cardinal(Action.Arg(4)), Action.Arg(6), 0, Cardinal(Action.Arg(5)));
end;

procedure TPSPMp4.hDelete;
begin
  var F := FileAt(FHLE.Arg(0));
  if F <> nil then
  begin
    for var I := FRegs.Count - 1 downto 0 do
      if FRegs[I].Mp4 = F then
        FRegs.Delete(I);
    FFiles.Remove(F);
  end;
  FHLE.Result(0);
end;

procedure TPSPMp4.hGetMovieInfo;
begin
  var F := FileAt(FHLE.Arg(0));
  var Info := FHLE.Arg(1);
  if F = nil then
  begin
    FHLE.Result(ERROR_MP4_INVALID_VALUE);
    Exit;
  end;
  if Info <> 0 then
  begin
    FMemory.Write32(Info, Cardinal(F.Tracks.Count));
    FMemory.Write32(Info + 4, 0);
  end;
  FHLE.Result(0);
end;

function TrackKind(const Handler: string): Integer;
begin
  if Handler = 'vide' then
    Result := $11
  else if Handler = 'soun' then
    Result := $10
  else
    Result := 0;
end;

procedure TPSPMp4.hGetNumberOfSpecificTrack;
begin
  var F := FileAt(FHLE.Arg(0));
  var Kind := FHLE.ArgInt(1);
  if F = nil then
  begin
    FHLE.Result(ERROR_MP4_INVALID_VALUE);
    Exit;
  end;
  var N := 0;
  for var T in F.Tracks do
    if TrackKind(T.Handler) = Kind then
      Inc(N);
  FHLE.Result(Cardinal(N));
end;

procedure TPSPMp4.hRegistTrack;
begin
  var F := FileAt(FHLE.Arg(0));
  var Kind := FHLE.ArgInt(1);
  var Num := FHLE.ArgInt(2);
  var TrackPtr := FHLE.Arg(4);
  if F = nil then
  begin
    FHLE.Result(ERROR_MP4_INVALID_VALUE);
    Exit;
  end;
  var Found: TPSPMp4Track := nil;
  var N := 0;
  for var T in F.Tracks do
    if TrackKind(T.Handler) = Kind then
    begin
      if N = Num then
      begin
        Found := T;
        Break;
      end;
      Inc(N);
    end;
  if Found = nil then
  begin
    FHLE.Result(ERROR_MP4_INVALID_VALUE);
    Exit;
  end;
  var R := RegAt(TrackPtr);
  if R = nil then
  begin
    R := TPSPMp4Reg.Create;
    R.Address := TrackPtr;
    FRegs.Add(R);
  end;
  R.Mp4 := F;
  R.Track := Found;
  R.Next := 0;
  R.Buffered := 0;
  FHLE.Result(0);
end;

procedure TPSPMp4.hUnregistTrack;
begin
  var R := RegAt(FHLE.Arg(1));
  if R <> nil then
    FRegs.Remove(R);
  FHLE.Result(0);
end;

procedure TPSPMp4.hQueryMemSize;
begin
  var Samples := FHLE.ArgInt(1);
  var MaxSize := FHLE.ArgInt(2);
  var ReadSize := FHLE.ArgInt(4);
  FHLE.Result(Cardinal(Samples) * (AlignUp(Cardinal(MaxSize), 64) + 64) + Cardinal(ReadSize));
end;

procedure TPSPMp4.hConstruct;
begin
  var R := RegAt(FHLE.Arg(1));
  if R = nil then
  begin
    FHLE.Result(ERROR_MP4_INVALID_VALUE);
    Exit;
  end;
  R.Capacity := FHLE.ArgInt(4);
  R.MaxSampleSize := FHLE.ArgInt(5);
  R.Buffered := 0;
  FHLE.Result(0);
end;

procedure TPSPMp4.hDestruct;
begin
  FHLE.Result(0);
end;

procedure TPSPMp4.hGetAvcTrackInfoData;
begin
  var R := RegAt(FHLE.Arg(1));
  var Info := FHLE.Arg(2);
  if R = nil then
  begin
    FHLE.Result(ERROR_MP4_INVALID_VALUE);
    Exit;
  end;
  if Info <> 0 then
  begin
    FMemory.Write32(Info, R.Track.TimeScale);
    FMemory.Write32(Info + 4, Cardinal(R.Track.Duration));
    FMemory.Write32(Info + 8, Cardinal(Length(R.Track.Samples)));
    FMemory.Write32(Info + 12, Cardinal(R.Track.Width));
    FMemory.Write32(Info + 16, Cardinal(R.Track.Height));
  end;
  FHLE.Result(0);
end;

procedure TPSPMp4.hFlush;
begin
  var R := RegAt(FHLE.Arg(1));
  if R <> nil then
    R.Buffered := 0;
  FHLE.Result(0);
end;

procedure TPSPMp4.hPutSampleNum;
begin
  var R := RegAt(FHLE.Arg(1));
  if R = nil then
  begin
    FHLE.Result(ERROR_MP4_INVALID_VALUE);
    Exit;
  end;
  R.Next := Max(0, Min(FHLE.ArgInt(2), Length(R.Track.Samples)));
  R.Buffered := 0;
  FHLE.Result(0);
end;

procedure TPSPMp4.hAvailableSize;
begin
  var R := RegAt(FHLE.Arg(1));
  if R = nil then
  begin
    FHLE.Result(ERROR_MP4_INVALID_VALUE);
    Exit;
  end;
  var Writable := Max(0, Min(R.Capacity - R.Buffered, Length(R.Track.Samples) - R.Next - R.Buffered));
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), Cardinal(Writable));
  if FHLE.Arg(3) <> 0 then
    FMemory.Write32(FHLE.Arg(3), Cardinal(Writable * R.MaxSampleSize));
  FHLE.Result(0);
end;

procedure TPSPMp4.hPut;
begin
  var R := RegAt(FHLE.Arg(1));
  if R = nil then
  begin
    FHLE.Result(ERROR_MP4_INVALID_VALUE);
    Exit;
  end;
  var N := Max(0, Min(FHLE.ArgInt(2), Length(R.Track.Samples) - R.Next - R.Buffered));
  N := Min(N, R.Capacity - R.Buffered);
  Inc(R.Buffered, N);
  FHLE.Result(Cardinal(N));
end;

procedure TPSPMp4.hGetAvcAu;
begin
  var R := RegAt(FHLE.Arg(1));
  var Au := FHLE.Arg(2);
  if R = nil then
  begin
    FHLE.Result(ERROR_MP4_INVALID_VALUE);
    Exit;
  end;
  if (R.Buffered <= 0) or (R.Next >= Length(R.Track.Samples)) then
  begin
    FHLE.Result(ERROR_MP4_NO_MORE_DATA);
    Exit;
  end;
  var S := R.Track.Samples[R.Next];
  Inc(R.Next);
  Dec(R.Buffered);
  var Data := R.Mp4.Data;
  var Out_: TBytes := nil;
  if S.Key then
    Out_ := Copy(R.Track.ParamSets);
  var P := S.Offset;
  var Stop := Min(S.Offset + S.Size, Int64(Length(Data)));
  while P + R.Track.NalLength <= Stop do
  begin
    var L: Int64 := 0;
    for var I := 0 to R.Track.NalLength - 1 do
      L := (L shl 8) or Data[P + I];
    Inc(P, R.Track.NalLength);
    if (L <= 0) or (P + L > Stop) then
      Break;
    Out_ := Out_ + [0, 0, 0, 1] + Copy(Data, P, L);
    Inc(P, L);
  end;
  var Es := FMemory.Read32(Au + 16);
  if (Es <> 0) and (Length(Out_) > 0) and FMemory.Valid(Es, Length(Out_)) then
    FMemory.WriteBytes(Es, Out_[0], Length(Out_));
  var Scale := R.Track.TimeScale;
  if Scale = 0 then
    Scale := 90000;
  var Pts := S.Cts * 90000 div Scale;
  var Dts := S.Dts * 90000 div Scale;
  FMemory.Write32(Au, Cardinal(Pts shr 32));
  FMemory.Write32(Au + 4, Cardinal(Pts));
  FMemory.Write32(Au + 8, Cardinal(Dts shr 32));
  FMemory.Write32(Au + 12, Cardinal(Dts));
  FMemory.Write32(Au + 20, Cardinal(Length(Out_)));
  FHLE.Result(0);
end;

initialization
  RegisterPSPService(TPSPMp4);

end.
