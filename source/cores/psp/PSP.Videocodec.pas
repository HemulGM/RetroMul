unit PSP.Videocodec;

// sceVideocodec as a guest libmpeg drives it: one H.264 decoder per codec
// block, from sceVideocodecOpen to sceVideocodecDelete. The block carries the
// access unit (+24 address, +28 size), the picture information at [+10]
// (+08 width, +0C height, +10..+1C crop, +20 pictures completed) and the
// pictures at [+2C], four entries of 2C bytes: the eight plane addresses of
// the ME's two-field layout (what sceMpegBaseCscAvc and sceMpegBaseYCrCbCopy
// read) and a frame number. +14 is the EDRAM sceVideocodecGetEDRAM hands out.
// Addresses below 2 MB are the ME's own memory, where libmpeg keeps the AVC
// ES buffers that sceMpegBasePESpacketCopy fills.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Generics.Collections, PSP.Types, PSP.Memory, PSP.HLE,
  PSP.Kernel, PSP.Service, PSP.MpegVideo;

type
  TPSPVideoDecoder = class
  public
    Block: Cardinal;
    Avc: TPSPAvc;
    // Guest buffers the pictures are handed out in, one per entry.
    Buffers: array[0..3] of Cardinal;
    MbW, MbH: Integer;
    Frames: Cardinal;
    constructor Create(ABlock: Cardinal);
    destructor Destroy; override;
  end;

  TPSPVideocodec = class(TPSPService)
  private
    FDecoders: TObjectDictionary<Cardinal, TPSPVideoDecoder>;
    FEdram: Cardinal;
    FMeRam: TBytes;
    function DecoderOf(Block: Cardinal): TPSPVideoDecoder;
    procedure FreeBuffers(D: TPSPVideoDecoder);
    procedure Publish(D: TPSPVideoDecoder; const Pictures: TArray<TPSPPicture>);
    procedure Delay(Us: Int64; Value: Cardinal);
    procedure hOpen;
    procedure hInit;
    procedure hDecode;
    procedure hStop;
    procedure hDelete;
    procedure hSetMemory;
    procedure hGetEDRAM;
    procedure hReleaseEDRAM;
  public
    constructor Create(System: TPSPSystem); override;
    destructor Destroy; override;
    procedure Reset; override;
    procedure Register; override;
    // A range of the ME's memory, nil when Address is not in it.
    function MePtr(Address, Size: Cardinal): PByte;
  end;

const
  PSPMeRamSize = $200000;

implementation

uses
  System.Math, PSP.CPU;

const
  LibCodec = 'sceVideocodec';
  MaxPictures = 4;
  PictureEntry = $2C;

{ TPSPVideoDecoder }

constructor TPSPVideoDecoder.Create(ABlock: Cardinal);
begin
  inherited Create;
  Block := ABlock;
  Avc := TPSPAvc.Create;
end;

destructor TPSPVideoDecoder.Destroy;
begin
  Avc.Free;
  inherited;
end;

{ TPSPVideocodec }

constructor TPSPVideocodec.Create(System: TPSPSystem);
begin
  inherited Create(System);
  FDecoders := TObjectDictionary<Cardinal, TPSPVideoDecoder>.Create([doOwnsValues]);
end;

destructor TPSPVideocodec.Destroy;
begin
  FDecoders.Free;
  inherited;
end;

procedure TPSPVideocodec.Reset;
begin
  // Guest memory goes with the machine.
  FDecoders.Clear;
  FEdram := 0;
  FMeRam := nil;
end;

function TPSPVideocodec.MePtr(Address, Size: Cardinal): PByte;
begin
  var A := Address and $1FFFFFFF;
  if (A >= PSPMeRamSize) or (Size > PSPMeRamSize - A) then
    Exit(nil);
  if FMeRam = nil then
    SetLength(FMeRam, PSPMeRamSize);
  Result := @FMeRam[A];
end;

procedure TPSPVideocodec.Register;
begin
  var H := FHLE;
  H.Register(LibCodec, $C01EC829, 'sceVideocodecOpen', hOpen);
  H.Register(LibCodec, $17099F0A, 'sceVideocodecInit', hInit);
  H.Register(LibCodec, $DBA273FA, 'sceVideocodecDecode', hDecode);
  H.Register(LibCodec, $A2F0564E, 'sceVideocodecStop', hStop);
  H.Register(LibCodec, $307E6E1C, 'sceVideocodecDelete', hDelete);
  H.Register(LibCodec, $745A7B7A, 'sceVideocodecSetMemory', hSetMemory);
  H.Register(LibCodec, $2D31F5B1, 'sceVideocodecGetEDRAM', hGetEDRAM);
  H.Register(LibCodec, $4F160BF4, 'sceVideocodecReleaseEDRAM', hReleaseEDRAM);
end;

function TPSPVideocodec.DecoderOf(Block: Cardinal): TPSPVideoDecoder;
begin
  if not FDecoders.TryGetValue(Block, Result) then
  begin
    Result := TPSPVideoDecoder.Create(Block);
    FDecoders.Add(Block, Result);
  end;
end;

procedure TPSPVideocodec.FreeBuffers(D: TPSPVideoDecoder);
begin
  for var I := 0 to MaxPictures - 1 do
    if D.Buffers[I] <> 0 then
    begin
      FKernel.KernelPartition.FreeBlock(D.Buffers[I]);
      D.Buffers[I] := 0;
    end;
  D.MbW := 0;
  D.MbH := 0;
end;

procedure TPSPVideocodec.Delay(Us: Int64; Value: Cardinal);
begin
  FHLE.Result(Value);
  if not FKernel.CanWait then
    Exit;
  var T := FKernel.Current;
  FKernel.BeginWait(PSPWaitDelay, nil, 0, 0, False, nil, nil, 'vcodec');
  if T.Wait.HLETag <> 'vcodec' then
    Exit;
  T.Wait.Data[0] := Value;
  FKernel.AddWakeTimer(FKernel.Scheduler.Now + Us * 1000, T, 'vcodec', Value, 0);
end;

procedure TPSPVideocodec.Publish(D: TPSPVideoDecoder; const Pictures: TArray<TPSPPicture>);
begin
  var Block := D.Block;
  var Info := FMemory.Read32(Block + $10);
  var Entries := FMemory.Read32(Block + $2C);
  var N := Min(Length(Pictures), MaxPictures);
  if (Entries = 0) or not FMemory.Valid(Entries, MaxPictures * PictureEntry) then
    N := 0;
  for var I := 0 to N - 1 do
  begin
    var P := Pictures[I];
    var MbW := (P.Width + 15) div 16;
    var MbH := (P.Height + 15) div 16;
    var Sizes: TArray<Cardinal>;
    var Total := PSPMePlaneSizes(MbW, MbH, Sizes);
    if (MbW <> D.MbW) or (MbH <> D.MbH) then
    begin
      FreeBuffers(D);
      D.MbW := MbW;
      D.MbH := MbH;
    end;
    if D.Buffers[I] = 0 then
      D.Buffers[I] := FKernel.AllocKernel(Total, 'videocodec picture');
    if D.Buffers[I] = 0 then
    begin
      N := I;
      Break;
    end;
    var Planes: TPSPMePlanes;
    var A := D.Buffers[I];
    var E := Entries + Cardinal(I * PictureEntry);
    for var K := 0 to 7 do
    begin
      Planes[K] := FMemory.Ptr(A, Sizes[K]);
      FMemory.Write32(E + Cardinal(K) * 4, A);
      Inc(A, Sizes[K]);
    end;
    PSPWriteMePlanes(P, Planes, MbW, MbH);
    FMemory.Touched(D.Buffers[I], Total);
    FMemory.Write32(E + $20, D.Frames);
    FMemory.Write32(E + $24, 0);
    FMemory.Write32(E + $28, 0);
    Inc(D.Frames);
  end;
  if (Info <> 0) and FMemory.Valid(Info, $24) then
  begin
    var W, H: Integer;
    if N > 0 then
    begin
      W := Pictures[0].Width;
      H := Pictures[0].Height;
    end
    else
    begin
      var Sps := D.Avc.ActiveSps;
      W := Sps.MBWidth * 16;
      H := Sps.MBHeight * 16;
    end;
    FMemory.Write32(Info + $08, Cardinal(W));
    FMemory.Write32(Info + $0C, Cardinal(H));
    for var K := 0 to 3 do
      FMemory.Write32(Info + $10 + Cardinal(K) * 4, 0);
    FMemory.Write32(Info + $20, Cardinal(N));
  end;
  FMemory.Write32(Block + $08, 0);
end;

procedure TPSPVideocodec.hOpen;
begin
  var Block := FHLE.Arg(0);
  if (Block = 0) or not FMemory.Valid(Block, $50) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  var D: TPSPVideoDecoder;
  if FDecoders.TryGetValue(Block, D) then
  begin
    FreeBuffers(D);
    FDecoders.Remove(Block);
  end;
  DecoderOf(Block);
  FHLE.Result(0);
end;

procedure TPSPVideocodec.hInit;
begin
  DecoderOf(FHLE.Arg(0)).Avc.Reset;
  FHLE.Result(0);
end;

procedure TPSPVideocodec.hSetMemory;
begin
  FHLE.Result(0);
end;

function DecodeTimeUs(MbW, MbH: Integer): Int64;
begin
  // The ME takes about 5 us per macroblock.
  Result := 100 + Int64(MbW) * MbH * 5;
end;

procedure TPSPVideocodec.hDecode;
begin
  var Block := FHLE.Arg(0);
  var D := DecoderOf(Block);
  var Addr := FMemory.Read32(Block + $24);
  var Size := FMemory.Read32(Block + $28);
  var Data: TBytes := nil;
  if (Size > 0) and (Size < $100000) then
  begin
    var Src := MePtr(Addr, Size);
    if Src = nil then
      Src := FMemory.Ptr(Addr, Size);
    if Src <> nil then
    begin
      SetLength(Data, Size);
      Move(Src^, Data[0], Size);
    end;
  end;
  var Pictures: TArray<TPSPPicture> := nil;
  if Length(Data) > 0 then
  begin
    var Err := D.Avc.Decode(Data, Pictures);
    if Err <> 0 then
    begin
      FMemory.Write32(Block + $08, Err);
      FHLE.Result(Err);
      Exit;
    end;
  end;
  Publish(D, Pictures);
  var Sps := D.Avc.ActiveSps;
  Delay(DecodeTimeUs(Sps.MBWidth, Sps.MBHeight), 0);
end;

procedure TPSPVideocodec.hStop;
begin
  // The pictures the decoder still holds.
  var D := DecoderOf(FHLE.Arg(0));
  var Pictures: TArray<TPSPPicture>;
  D.Avc.Drain(Pictures);
  Publish(D, Pictures);
  FHLE.Result(0);
end;

procedure TPSPVideocodec.hDelete;
begin
  var Block := FHLE.Arg(0);
  var D: TPSPVideoDecoder;
  if FDecoders.TryGetValue(Block, D) then
  begin
    FreeBuffers(D);
    FDecoders.Remove(Block);
  end;
  FHLE.Result(0);
end;

procedure TPSPVideocodec.hGetEDRAM;
begin
  var Block := FHLE.Arg(0);
  if FEdram = 0 then
    FEdram := FKernel.AllocKernel($100, 'videocodec edram');
  if FEdram = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
    Exit;
  end;
  if FMemory.Valid(Block + $14, 4) then
    FMemory.Write32(Block + $14, FEdram);
  FHLE.Result(0);
end;

procedure TPSPVideocodec.hReleaseEDRAM;
begin
  var Block := FHLE.Arg(0);
  if FEdram <> 0 then
    FKernel.KernelPartition.FreeBlock(FEdram);
  FEdram := 0;
  if FMemory.Valid(Block + $14, 4) then
    FMemory.Write32(Block + $14, 0);
  FHLE.Result(0);
end;

initialization
  RegisterPSPService(TPSPVideocodec);

end.
