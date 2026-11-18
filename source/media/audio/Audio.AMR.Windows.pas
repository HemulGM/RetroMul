unit Audio.AMR.Windows;

interface

uses
  System.SysUtils, Audio.Types;

function WindowsAMRAvailable: Boolean;

function OpenWindowsAMR(const Data: TBytes; PacketCount: Integer): IAudioSource;

implementation

uses
  System.Classes, System.Math, Winapi.Windows, Winapi.ActiveX, Audio.Decoder;

const
  MFVersion = $00020070;
  LoadFromSystem32 = $00000800;
  FirstAudioStream = DWORD($FFFFFFFD);
  ReaderError = $0001;
  ReaderEndOfStream = $0002;
  ReaderTypeChanged = $0020;
  DecoderCategory: TGUID = '{9EA73FB4-EF7A-4559-8D5D-719D8F0426C7}';
  MediaTypeAudio: TGUID = '{73647561-0000-0010-8000-00AA00389B71}';
  MediaSubtypeAMR: TGUID = '{00007361-0000-0010-8000-00AA00389B71}';
  MediaSubtypePCM: TGUID = '{00000001-0000-0010-8000-00AA00389B71}';
  MajorTypeKey: TGUID = '{48EBA18E-F8C9-4687-BF11-0A74C9F96A8F}';
  SubtypeKey: TGUID = '{F7E34C9A-42E8-4714-B74B-CB29D72C35E5}';
  ChannelsKey: TGUID = '{37E48BF5-645E-4C5B-89DE-ADA9E29B696A}';
  RateKey: TGUID = '{5FAEEAE7-0290-4C31-9E8A-C534F68D9DBA}';
  BitsKey: TGUID = '{F2DEB57F-40FA-4764-AA33-ED4F2D1FF669}';
  OriginNameKey: TGUID = '{FC358288-3CB6-460C-A424-B6681260375A}';
  ContentTypeKey: TGUID = '{FC358289-3CB6-460C-A424-B6681260375A}';
  SampleRate = 8000;

type
  // Media Foundation COM ABI from mfobjects.h and mfreadwrite.h.
  // The unused methods reserve their documented vtable slots.
  IMFAttributes = interface(IUnknown)
    ['{2CD2D921-C447-44A7-A13C-4ADABFC247E3}']
    procedure GetItem; stdcall;
    procedure GetItemType; stdcall;
    procedure CompareItem; stdcall;
    procedure Compare; stdcall;
    function GetUINT32(const Key: TGUID; out Value: DWORD): HRESULT; stdcall;
    procedure GetUINT64; stdcall;
    procedure GetDouble; stdcall;
    function GetGUID(const Key: TGUID; out Value: TGUID): HRESULT; stdcall;
    procedure GetStringLength; stdcall;
    procedure GetString; stdcall;
    procedure GetAllocatedString; stdcall;
    procedure GetBlobSize; stdcall;
    procedure GetBlob; stdcall;
    procedure GetAllocatedBlob; stdcall;
    procedure GetUnknown; stdcall;
    procedure SetItem; stdcall;
    procedure DeleteItem; stdcall;
    procedure DeleteAllItems; stdcall;
    function SetUINT32(const Key: TGUID; Value: DWORD): HRESULT; stdcall;
    procedure SetUINT64; stdcall;
    procedure SetDouble; stdcall;
    function SetGUID(const Key, Value: TGUID): HRESULT; stdcall;
    function SetString(const Key: TGUID; Value: PWideChar): HRESULT; stdcall;
    procedure SetBlob; stdcall;
    procedure SetUnknown; stdcall;
    procedure LockStore; stdcall;
    procedure UnlockStore; stdcall;
    procedure GetCount; stdcall;
    procedure GetItemByIndex; stdcall;
    procedure CopyAllItems; stdcall;
  end;

  IMFMediaBuffer = interface(IUnknown)
    ['{045FA593-8799-42B8-BC8D-8968C6453507}']
    function Lock(out Data: PByte; MaxLength: PDWORD; out Length: DWORD): HRESULT; stdcall;
    function Unlock: HRESULT; stdcall;
  end;

  IMFSample = interface(IMFAttributes)
    ['{C40A00F2-B93A-4D80-AE8C-5A1C634F58E4}']
    procedure GetSampleFlags; stdcall;
    procedure SetSampleFlags; stdcall;
    procedure GetSampleTime; stdcall;
    procedure SetSampleTime; stdcall;
    procedure GetSampleDuration; stdcall;
    procedure SetSampleDuration; stdcall;
    procedure GetBufferCount; stdcall;
    procedure GetBufferByIndex; stdcall;
    function ConvertToContiguousBuffer(out Buffer: IMFMediaBuffer): HRESULT; stdcall;
  end;

  IMFSourceReader = interface(IUnknown)
    ['{70AE66F2-C809-4E4F-8915-BDCB406B7993}']
    procedure GetStreamSelection; stdcall;
    procedure SetStreamSelection; stdcall;
    procedure GetNativeMediaType; stdcall;
    function GetCurrentMediaType(Stream: DWORD; out MediaType: IMFAttributes): HRESULT; stdcall;
    function SetCurrentMediaType(Stream: DWORD; Reserved: Pointer; const MediaType: IMFAttributes): HRESULT; stdcall;
    procedure SetCurrentPosition; stdcall;
    function ReadSample(Stream, ControlFlags: DWORD; ActualStream: PDWORD; out Flags: DWORD; Timestamp: Pointer; out Sample: IMFSample): HRESULT; stdcall;
  end;

  TMFRegisterType = record
    MajorType, Subtype: TGUID;
  end;

  PMFRegisterType = ^TMFRegisterType;

  PMFActivations = ^TMFActivations;

  TMFActivations = array[0..(MaxInt div SizeOf(Pointer)) - 1] of Pointer;

  TWindowsAMRSource = class(TInterfacedObject, IAudioSource, IAudioMetadata)
  private
    FReader: IMFSourceReader;
    FPCM: TArray<SmallInt>;
    FOffset, FCount, FPacketCount: Integer;
    FEnded, FMFStarted, FOwnCOM: Boolean;
    procedure ValidateFormat;
    procedure ReadPacket;
  public
    constructor Create(const Data: TBytes; PacketCount: Integer);
    destructor Destroy; override;
    function GetFormat: TAudioFormat;
    function GetInfo: TAudioInfo;
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

type
  TMFExports = record
    Startup: function(Version, Flags: DWORD): HRESULT; stdcall;
    Shutdown: function: HRESULT; stdcall;
    CreateByteStream: function(const Stream: IStream; out ByteStream: IUnknown): HRESULT; stdcall;
    CreateMediaType: function(out MediaType: IMFAttributes): HRESULT; stdcall;
    EnumTransforms: function(Category: TGUID; Flags: DWORD; InputType, OutputType: PMFRegisterType; out Activations: PMFActivations; out Count: DWORD): HRESULT; stdcall;
    CreateReader: function(const ByteStream: IUnknown; Attributes: Pointer; out Reader: IMFSourceReader): HRESULT; stdcall;
  end;

var
  MF: TMFExports;
  MFPlatform, MFReader: HMODULE;
  AvailabilityLock: TObject;
  AvailabilityKnown, Available: Boolean;

procedure CheckMF(Status: HRESULT; const Operation: string);
begin
  if Failed(Status) then
    raise EReadError.CreateFmt('%s (0x%.8x)', [Operation, Cardinal(Status)]);
end;

function StartCOM: Boolean;
begin
  var Status := CoInitializeEx(nil, COINIT_MULTITHREADED);
  if Status = RPC_E_CHANGED_MODE then
    Exit(False);
  CheckMF(Status, 'AMR COM initialization failed');
  Result := True;
end;

function DiscoverWindowsAMR: Boolean;
begin
  // Windows editions without Media Foundation must still start normally.
  Result := False;
  MFPlatform := LoadLibraryEx('mfplat.dll', 0, LoadFromSystem32);
  MFReader := LoadLibraryEx('mfreadwrite.dll', 0, LoadFromSystem32);
  if (MFPlatform = 0) or (MFReader = 0) then
    Exit;

  @MF.Startup := GetProcAddress(MFPlatform, 'MFStartup');
  @MF.Shutdown := GetProcAddress(MFPlatform, 'MFShutdown');
  @MF.CreateByteStream := GetProcAddress(MFPlatform, 'MFCreateMFByteStreamOnStream');
  @MF.CreateMediaType := GetProcAddress(MFPlatform, 'MFCreateMediaType');
  @MF.EnumTransforms := GetProcAddress(MFPlatform, 'MFTEnumEx');
  @MF.CreateReader := GetProcAddress(MFReader, 'MFCreateSourceReaderFromByteStream');
  if not Assigned(MF.Startup) or not Assigned(MF.Shutdown) or not Assigned(MF.CreateByteStream) or
    not Assigned(MF.CreateMediaType) or not Assigned(MF.EnumTransforms) or not Assigned(MF.CreateReader) then
    Exit;

  var OwnCOM := StartCOM;
  try
    if Failed(MF.Startup(MFVersion, 0)) then
      Exit;
    try
      var InputType: TMFRegisterType;
      InputType.MajorType := MediaTypeAudio;
      InputType.Subtype := MediaSubtypeAMR;
      var Activations: PMFActivations := nil;
      var Count: DWORD := 0;
      // Include synchronous decoder MFTs used by the Source Reader.
      Result := Succeeded(MF.EnumTransforms(DecoderCategory, 1, @InputType, nil, Activations, Count)) and
        (Count > 0);
      if Activations <> nil then
      begin
        for var I := 0 to Integer(Count) - 1 do
          IUnknown(Activations^[I])._Release;
        CoTaskMemFree(Activations);
      end;
    finally
      MF.Shutdown;
    end;
  finally
    if OwnCOM then
      CoUninitialize;
  end;
end;

function WindowsAMRAvailable: Boolean;
begin
  TMonitor.Enter(AvailabilityLock);
  try
    if not AvailabilityKnown then
    begin
      Available := DiscoverWindowsAMR;
      AvailabilityKnown := True;
    end;
    Result := Available;
  finally
    TMonitor.Exit(AvailabilityLock);
  end;
end;

constructor TWindowsAMRSource.Create(const Data: TBytes; PacketCount: Integer);
begin
  inherited Create;
  FPacketCount := PacketCount;
  FOwnCOM := StartCOM;
  CheckMF(MF.Startup(MFVersion, 0), 'AMR Media Foundation startup failed');
  FMFStarted := True;
  var Stream: IStream := TStreamAdapter.Create(TBytesStream.Create(Data), soOwned);
  var ByteStream: IUnknown;
  CheckMF(MF.CreateByteStream(Stream, ByteStream), 'AMR byte stream creation failed');
  var Attributes: IMFAttributes;
  CheckMF(ByteStream.QueryInterface(IMFAttributes, Attributes), 'AMR byte stream attributes unavailable');
  CheckMF(Attributes.SetString(OriginNameKey, 'clip.amr'), 'AMR origin name failed');
  CheckMF(Attributes.SetString(ContentTypeKey, 'audio/amr'), 'AMR content type failed');
  CheckMF(MF.CreateReader(ByteStream, nil, FReader), 'AMR source reader creation failed');

  var PCMType: IMFAttributes;
  CheckMF(MF.CreateMediaType(PCMType), 'AMR PCM media type creation failed');
  CheckMF(PCMType.SetGUID(MajorTypeKey, MediaTypeAudio), 'AMR PCM major type failed');
  CheckMF(PCMType.SetGUID(SubtypeKey, MediaSubtypePCM), 'AMR PCM subtype failed');
  CheckMF(FReader.SetCurrentMediaType(FirstAudioStream, nil, PCMType), 'AMR PCM decoder negotiation failed');
  ValidateFormat;
end;

destructor TWindowsAMRSource.Destroy;
begin
  FReader := nil;
  if FMFStarted then
    MF.Shutdown;
  if FOwnCOM then
    CoUninitialize;
  inherited;
end;

procedure TWindowsAMRSource.ValidateFormat;
begin
  var MediaType: IMFAttributes;
  var Channels, Rate, Bits: DWORD;
  var Subtype: TGUID;
  CheckMF(FReader.GetCurrentMediaType(FirstAudioStream, MediaType), 'AMR output type unavailable');
  CheckMF(MediaType.GetGUID(SubtypeKey, Subtype), 'AMR output subtype unavailable');
  CheckMF(MediaType.GetUINT32(ChannelsKey, Channels), 'AMR output channels unavailable');
  CheckMF(MediaType.GetUINT32(RateKey, Rate), 'AMR output sample rate unavailable');
  CheckMF(MediaType.GetUINT32(BitsKey, Bits), 'AMR output bit depth unavailable');
  if not IsEqualGUID(Subtype, MediaSubtypePCM) or (Channels <> 1) or (Rate <> SampleRate) or (Bits <> 16) then
    raise EReadError.Create('Unsupported AMR decoder output format');
end;

procedure TWindowsAMRSource.ReadPacket;
begin
  var Sample: IMFSample;
  var Flags: DWORD;
  CheckMF(FReader.ReadSample(FirstAudioStream, 0, nil, Flags, nil, Sample), 'AMR sample decoding failed');
  if Flags and ReaderError <> 0 then
    raise EReadError.Create('AMR source reader reported an error');
  FEnded := Flags and ReaderEndOfStream <> 0;
  if Flags and ReaderTypeChanged <> 0 then
    ValidateFormat;
  FOffset := 0;
  FCount := 0;
  if Sample = nil then
    Exit;
  var Buffer: IMFMediaBuffer;
  CheckMF(Sample.ConvertToContiguousBuffer(Buffer), 'AMR PCM buffer unavailable');
  var Data: PByte;
  var ByteCount: DWORD;
  CheckMF(Buffer.Lock(Data, nil, ByteCount), 'AMR PCM buffer lock failed');
  try
    if (ByteCount > 128 * 1024) or Odd(ByteCount) or ((ByteCount > 0) and (Data = nil)) then
      raise EReadError.Create('Invalid AMR PCM buffer');
    FCount := ByteCount div SizeOf(SmallInt);
    if FCount > Length(FPCM) then
      SetLength(FPCM, FCount);
    if FCount > 0 then
      Move(Data^, FPCM[0], ByteCount);
  finally
    Buffer.Unlock;
  end;
end;

function TWindowsAMRSource.GetFormat: TAudioFormat;
begin
  Result.SampleRate := SampleRate;
  Result.Channels := 1;
end;

function TWindowsAMRSource.GetInfo: TAudioInfo;
begin
  Result := Default(TAudioInfo);
  Result.SampleRate := SampleRate;
  Result.Channels := 1;
  Result.TrackCount := 1;
  Result.FormatName := 'AMR-NB';
  Result.TrackDurations := [FPacketCount / 50];
end;

function TWindowsAMRSource.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, 1);
  Result := 0;
  var EmptyPackets := 0;
  while Result < Frames do
  begin
    if FOffset = FCount then
    begin
      if FEnded then
        Break;
      ReadPacket;
      if FCount = 0 then
      begin
        Inc(EmptyPackets);
        if EmptyPackets > 64 then
          raise EReadError.Create('AMR source reader returned no PCM');
        Continue;
      end;
      EmptyPackets := 0;
    end;
    var Count := Min(Frames - Result, FCount - FOffset);
    Move(FPCM[FOffset], Samples[Result], Count * SizeOf(SmallInt));
    Inc(FOffset, Count);
    Inc(Result, Count);
  end;
end;

function OpenWindowsAMR(const Data: TBytes; PacketCount: Integer): IAudioSource;
begin
  if not WindowsAMRAvailable then
    raise ENotSupportedException.Create('Windows AMR-NB decoder is unavailable');
  Result := TWindowsAMRSource.Create(Data, PacketCount);
end;

initialization
  AvailabilityLock := TObject.Create;

finalization
  if MFReader <> 0 then
    FreeLibrary(MFReader);
  if MFPlatform <> 0 then
    FreeLibrary(MFPlatform);
  AvailabilityLock.Free;

end.

