unit PSP.State.Schema;

// Only explicitly described POD records may bypass field traversal. Native
// render/cache fields are omitted and rebuilt against the new memory objects.
interface

{$RTTI EXPLICIT FIELDS([vcPrivate, vcProtected, vcPublic, vcPublished]) METHODS([vcPrivate, vcProtected, vcPublic,
  vcPublished]) PROPERTIES([vcPublic, vcPublished])}

uses
  PSP.State.Graph;

function NewPSPStateSchema: TPSPGraphSchema;

implementation

uses
  System.SysUtils, System.Classes, System.TypInfo, System.Generics.Collections,
  Core.Emulation.Types, PSP.CPU, PSP.Memory, PSP.Kernel, PSP.Scheduler, PSP.HLE,
  PSP.IO, PSP.Loader, PSP.Display, PSP.Service, PSP.Audio, PSP.Font, PSP.GE,
  PSP.GE.Types, PSP.GE.Engine, PSP.SAS, PSP.SysLibs, PSP.Misc, PSP.MP3,
  PSP.Atrac, PSP.Mpeg, PSP.MpegDemux, PSP.MpegVideo, PSP.Jpeg, PSP.Net,
  PSP.Utility, PSP.Videocodec, Audio.MP3.Layer3, Core.Snapshots,
  PSP.State.Action, Video.AVC.H264, Video.AVC.H264.Syntax, Video.AVC.Types,
  FMXAudio.Transform;

type
  TU32x2 = array[0..1] of Cardinal;

  TU32x3 = array[0..2] of Cardinal;

  TU32x4 = array[0..3] of Cardinal;

  TU32x8 = array[0..7] of Cardinal;

  TU32x16 = array[0..15] of Cardinal;

  TU32x32 = array[0..31] of Cardinal;

  TI32x4 = array[0..3] of Integer;

  TI32x3 = array[0..2] of Integer;

  TI16x28 = array[0..27] of SmallInt;

  TByte2 = array[0..1] of Byte;

  TByte4 = array[0..3] of Byte;

  TByte1024 = array[0..1023] of Byte;

  TAudioChannels = array[0..PSPAudioChannelCount - 1] of TPSPAudioChannel;

  TAudioBlock = array[0..PSPAudioBlock * 2 - 1] of Integer;

  TAudioDescriptors = array[0..1] of TPSPAudioDescriptor;

  TCtrlSamples = array[0..63] of TPSPCtrlSample;

  TFontTables = array[0..3] of TArray<TPGFMetric>;

  TGELists = array[0..GEListCount - 1] of TGEList;

  TGECallbacks = array[0..GECallbackCount - 1] of TGECallback;

  TGEHWStack = array[0..1] of TGECallStackEntry;

  TGEVertices = array[0..2] of TGEAsmVertex;

  TReadyQueues = array[0..127] of TList<TPSPThread>;

  TSubInterrupts = array[0..66, 0..31] of TPSPInterruptHandler;

  TInterrupts = array[0..67] of TPSPInterruptHandler;

  TDeadlines = array[TPSPEvent] of Int64;

  TSasVoices = array[0..PSPSasVoices - 1] of TPSPSasVoice;

  TDialogs = array[TPSPDialogType] of TPSPDialog;

  TJpegPlanes = array[0..2] of TBytes;

  TMp3Handles = array[0..1] of TPSPMp3Handle;

  TMpegEsBuffers = array[1..2] of TPSPMpegEsBuf;

  TPackQueues = array[0..3] of TPSPEsQueue;

  TPackEnds = array[0..3] of Int64;

  TAvcSps = array[0..31] of TPSPAvcSps;

  TAvcPps = array[0..255] of Integer;

  TAvcBottom = array[0..255] of Boolean;

  TAvcSlots = array[0..1] of TPSPSeiRecord;

  TApctlHandlers = array[0..1] of TNetHandler;

  TAdhocHandlers = array[0..3] of TNetHandler;

function NewPSPStateSchema: TPSPGraphSchema;
begin
  Result := TPSPGraphSchema.Create;
  try
    Result.AddPublicTypes(['PSP.', 'Audio.ATRAC3', 'Audio.MP3', 'Audio.MPEG', 'Video.AVC']);
    RegisterPSPKernelStateTypes(Result);
    Result.Optional(TPSPStateAction, ['Failure', 'Arrays', 'Buffers', 'Texts', 'Results', 'Owned']);
    Result.Optional(TPSPIO, ['FFatNames', 'FAsyncStub', 'FAsyncPriority', 'FMemstickInserted', 'FMemstickCallbacks']);
    Result.Optional(TPSPOpenFile, ['AsyncWorker', 'AsyncPriority', 'AsyncLatency', 'AsyncTask']);
    Result.Optional(TPSPAudio, ['FO2WaitFailed']);
    Result.Optional(TPSPThread, ['BusyYieldEqual']);
    Result.Optional(TPSPAtracSlot, ['Decoded']);
    Result.AddClass(TMemoryStream, []);
    Result.AddClass(TFileStream, []);
    Result.AddClass(TStringBuilder, []);
    Result.AddClass(TInverseMDCT, []);
    Result.AddClass(TObjectDictionary<string, TDictionary<Cardinal, Cardinal>>, []);
    Result.Native(TMP3Layer3Decoder,
      function: TObject
      begin
        Result := TMP3Layer3Decoder.Create;
      end,
      procedure(Instance: TObject; State: TStateArchive)
      begin
        TMP3Layer3Decoder(Instance).SerializeState(State);
      end);
    Result.AddClass(TPSPCPU, ['FDecoded', 'FPages', 'FOnSyscall', 'FOnBreak', 'Runner']);
    Result.AddClass(TPSPHLE, ['FOnLog']);
    Result.AddClass(TPSPKernel, ['FOnExit', 'FOnSyncTime']);
    Result.AddClass(TPSPIO,
      ['FOnOutput', 'FOnScreenshot', 'FOnHostChange', 'FMemstickRoot', 'FFlashRoot', 'FHostRoot', 'FDisc']);
    Result.AddClass(TPSPLoader, ['FOnLoadExec']);
    Result.AddClass(TPSPSystem, ['FlashRoot', 'FontDirectory', 'Services']);
    Result.AddClass(TPSPUtility, ['FView', 'FSoftwareView']);
    // Slice-local readers and reference-list workspaces can retain sentinels
    // or removed pictures. The next access unit builds them from the DPB.
    Result.AddClass(TH264Decoder,
      ['FBits', 'FCABAC', 'FRemoveRefs', 'FPromoteRefs', 'FPromoteIndexes', 'FRefList', 'FRefList1']);
    Result.Factory(TH264Decoder,
      function: TObject
      begin
        Result := TH264Decoder.Create;
      end);
    Result.Plain(TypeInfo(TH264SPS));
    Result.Plain(TypeInfo(TH264PPS));

    Result.Plain(TypeInfo(TPSPContext));
    Result.Plain(TypeInfo(TEmulatorInput));
    Result.Plain(TypeInfo(TPGFLayout));
    Result.Plain(TypeInfo(TGEList));
    Result.Plain(TypeInfo(TGECallback));
    Result.Plain(TypeInfo(TGEAsmVertex));
    Result.Plain(TypeInfo(TGEVec3));
    Result.Plain(TypeInfo(TPSPGERegs));

    Result.Alias(TPSPCPU.ClassInfo, 'COP0', TypeInfo(TU32x32));
    Result.Alias(TPSPCPU.ClassInfo, 'VLatch', TypeInfo(TU32x4));
    Result.Alias(TPSPAudio.ClassInfo, 'FCh', TypeInfo(TAudioChannels));
    Result.Alias(TPSPAudio.ClassInfo, 'FBlock', TypeInfo(TAudioBlock));
    Result.Alias(TPSPAudio.ClassInfo, 'FO2Desc', TypeInfo(TAudioDescriptors));
    Result.Alias(TPSPDisplay.ClassInfo, 'FSamples', TypeInfo(TCtrlSamples));
    Result.Alias(TPGFFile.ClassInfo, 'FTables', TypeInfo(TFontTables));
    Result.Alias(TPSPGE.ClassInfo, 'FLists', TypeInfo(TGELists));
    Result.Alias(TPSPGE.ClassInfo, 'FCallbacks', TypeInfo(TGECallbacks));
    Result.Alias(TPSPGE.ClassInfo, 'FHWStack', TypeInfo(TGEHWStack));
    Result.Alias(TPSPGEEngine.ClassInfo, 'FClut', TypeInfo(TByte1024));
    Result.Alias(TPSPGEEngine.ClassInfo, 'FAsm', TypeInfo(TGEVertices));
    Result.Alias(TypeInfo(TPSPWait), 'Data', TypeInfo(TU32x8));
    Result.Alias(TPSPThread.ClassInfo, 'TlsSlots', TypeInfo(TU32x16));
    Result.Alias(TPSPKernel.ClassInfo, 'FReady', TypeInfo(TReadyQueues));
    Result.Alias(TPSPKernel.ClassInfo, 'FReadyMask', TypeInfo(TU32x4));
    Result.Alias(TPSPKernel.ClassInfo, 'FSubIntr', TypeInfo(TSubInterrupts));
    Result.Alias(TPSPKernel.ClassInfo, 'FIntrHandlers', TypeInfo(TInterrupts));
    Result.Alias(TPSPKernel.ClassInfo, 'FIdleThreadIds', TypeInfo(TU32x2));
    Result.Alias(TPSPModule.ClassInfo, 'Version', TypeInfo(TByte2));
    Result.Alias(TPSPScheduler.ClassInfo, 'FDue', TypeInfo(TDeadlines));
    Result.Alias(TPSPSysLibs.ClassInfo, 'FPowerCallbacks', TypeInfo(TU32x16));
    Result.Alias(TPSPMisc.ClassInfo, 'FErrorChar', TypeInfo(TU32x3));
    Result.Alias(TPSPSasCore.ClassInfo, 'FVoices', TypeInfo(TSasVoices));
    Result.Alias(TypeInfo(TPSPSasVoice), 'Rate', TypeInfo(TI32x4));
    Result.Alias(TypeInfo(TPSPSasVoice), 'Curve', TypeInfo(TI32x4));
    Result.Alias(TypeInfo(TPSPSasVoice), 'VagSamples', TypeInfo(TI16x28));
    Result.Alias(TPSPUtility.ClassInfo, 'FDialogs', TypeInfo(TDialogs));
    Result.Alias(TypeInfo(TPSPJpegImage), 'Planes', TypeInfo(TJpegPlanes));
    Result.Alias(TypeInfo(TVideoFrame), 'Planes', TypeInfo(TJpegPlanes));
    Result.Alias(TypeInfo(TVideoFrame), 'Strides', TypeInfo(TI32x3));
    Result.Alias(TPSPMp3FrameDecoder.ClassInfo, 'FLastHeader', TypeInfo(TByte4));
    Result.Alias(TPSPMp3.ClassInfo, 'FHandles', TypeInfo(TMp3Handles));
    Result.Alias(TPSPMpegInstance.ClassInfo, 'EsBufs', TypeInfo(TMpegEsBuffers));
    Result.Alias(TypeInfo(TPSPPackInfo), 'Queue', TypeInfo(TPackQueues));
    Result.Alias(TypeInfo(TPSPPackInfo), 'EsEnd', TypeInfo(TPackEnds));
    Result.Alias(TPSPAvc.ClassInfo, 'FSps', TypeInfo(TAvcSps));
    Result.Alias(TPSPAvc.ClassInfo, 'FPpsSps', TypeInfo(TAvcPps));
    Result.Alias(TPSPAvc.ClassInfo, 'FPpsBottom', TypeInfo(TAvcBottom));
    Result.Alias(TPSPAvc.ClassInfo, 'FSlots', TypeInfo(TAvcSlots));
    Result.Alias(TPSPNet.ClassInfo, 'FApctlHandlers', TypeInfo(TApctlHandlers));
    Result.Alias(TPSPNet.ClassInfo, 'FAdhocctlHandlers', TypeInfo(TAdhocHandlers));
    Result.Alias(TPSPVideoDecoder.ClassInfo, 'Buffers', TypeInfo(TU32x4));
  except
    Result.Free;
    raise;
  end;
end;

end.

