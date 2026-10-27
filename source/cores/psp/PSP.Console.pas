unit PSP.Console;

interface

uses
  System.SysUtils, System.UITypes, System.Generics.Collections,
  Core.Emulation.Types, PSP.Memory, PSP.Media, PSP.Executable, PSP.CPU,
  PSP.Kernel, PSP.FileSystem, Core.Storage, PSP.SystemHLE, PSP.GE, PSP.Audio,
  PSP.SAS, PSP.Utility, PSP.ATRAC, PSP.Controller, PSP.Mpeg, PSP.Registry, PSP.MP3;

const
  PSPFrameWidth = 480;
  PSPFrameHeight = 272;
  PSPFrameRate = 60 / 1.001;

type
  TPSPNativeModuleService = (pspGuestModule, pspNativeSAS, pspNativeATRAC, pspNativeMpeg, pspNativeMP3);

  TPSPLoadedModule = class
    Id, Block, Thread, StatusPointer: Cardinal;
    Started, Stopping, UnloadPending: Boolean;
    SelfUnloadThread, SelfExitCode, SelfStatusPointer: Cardinal;
    NativeService: TPSPNativeModuleService;
    Path: string;
    Executable: TPSPExecutable;
  end;

  // Native Allegrex/HLE runtime. Missing services retain module/NID diagnostics.
  TPSPConsole = class
  private
    FMemory: TPSPMemory;
    FCPU: TPSPCPU;
    FKernel: TPSPKernel;
    FFiles: TPSPFileSystem;
    FStorage: IStorage;
    FSystem: TPSPSystemHLE;
    FGE: TPSPGE;
    FAudio: TPSPAudio;
    FSAS: TPSPSAS;
    FUtility: TPSPUtility;
    FATRAC: TPSPATRAC;
    FMP3: TPSPMP3;
    FController: TPSPController;
    FMpeg: TPSPMpeg;
    FRegistry: TPSPRegistry;
    FAudioSamples: TArray<SmallInt>;
    FProgram, FNextProgram: TPSPProgram;
    FLoadExecPending: Boolean;
    FLaunchArguments: TBytes;
    FExecutable: TPSPExecutable;
    FModules: TObjectList<TPSPLoadedModule>;
    FImports: TArray<TPSPImport>;
    FInput: TEmulatorInput;
    FFramebuffer, FStride, FFormat: Cardinal;
    FPendingFramebuffer, FPendingStride, FPendingFormat: Cardinal;
    FPendingDisplay, FDisplayModeSet: Boolean;
    FDisplayHoldMode: Cardinal;
    FHCountOffset: Int64;
    FFrameNumber, FLastVBlank: UInt64;
    FRenderWorkerCount: Integer;
    procedure Syscall(CPU: TPSPCPU; Code: Cardinal);
    function CallImport(const Import: TPSPImport): Cardinal;
    procedure Advance(Time: UInt64);
    procedure LinkModules;
    procedure ModuleThreadExit(Id, Status: Cardinal);
    function ModuleGP(Address: Cardinal): Cardinal;
    function LastVideoPacket: TBytes;
    function ModuleCall(NID: Cardinal; out Value: Cardinal): Boolean;
    function UnloadModule(Module: TPSPLoadedModule): Cardinal;
    function SelfStopUnload(ExitCode, ArgSize, ArgPointer, StatusPointer, Options: Cardinal): Cardinal;
    procedure Render(out Frame: TEmulatorFrame);
    procedure SetRenderWorkerCount(Value: Integer);
  public
    constructor Create(const ProgramData: TPSPProgram; const Storage: IStorage = nil);
    destructor Destroy; override;
    procedure Reset;
    procedure RunFrame(out Frame: TEmulatorFrame);
    property Input: TEmulatorInput read FInput write FInput;
    property Memory: TPSPMemory read FMemory;
    property CPU: TPSPCPU read FCPU;
    property Kernel: TPSPKernel read FKernel;
    property VideoPacket: TBytes read LastVideoPacket;
    property Mpeg: TPSPMpeg read FMpeg;
    property AudioSamples: TArray<SmallInt> read FAudioSamples;
    property Utility: TPSPUtility read FUtility;
    property GE: TPSPGE read FGE;
    property RenderWorkerCount: Integer read FRenderWorkerCount write SetRenderWorkerCount;
  end;

implementation

uses
  System.Math, System.Classes{$IFDEF PSP_PROFILE},PSP.Profile{$ENDIF};

constructor TPSPConsole.Create(const ProgramData: TPSPProgram; const Storage: IStorage);
begin
  inherited Create;
  FProgram := ProgramData;
  FRenderWorkerCount := Min(4,TThread.ProcessorCount);
  FStorage := Storage;
  FMemory := TPSPMemory.Create;
  FCPU := TPSPCPU.Create(FMemory);
  FCPU.OnSyscall := Syscall;
  Reset;
end;

procedure TPSPConsole.SetRenderWorkerCount(Value: Integer);
begin
  if (Value<1) or (Value>4) then raise EArgumentOutOfRangeException.Create('PSP: render worker count');
  FRenderWorkerCount:=Value;
  if FGE<>nil then
  begin FGE.MaxRenderWorkers:=Value;FGE.ParallelRendering:=Value>1 end;
end;

destructor TPSPConsole.Destroy;
begin
  FMpeg.Free;
  FModules.Free;
  FAudio.Free;
  FController.Free;
  FATRAC.Free;
  FMP3.Free;
  FUtility.Free;
  FSAS.Free;
  FGE.Free;
  FRegistry.Free;
  FSystem.Free;
  FKernel.Free;
  FFiles.Free;
  FCPU.Free;
  FMemory.Free;
  inherited;
end;

procedure TPSPConsole.Reset;
begin
  FLoadExecPending := False;
  FNextProgram := Default(TPSPProgram);
  FreeAndNil(FMpeg);
  FreeAndNil(FModules);
  FreeAndNil(FAudio);
  FreeAndNil(FController);
  FreeAndNil(FATRAC);
  FreeAndNil(FMP3);
  FreeAndNil(FUtility);
  FreeAndNil(FSAS);
  FreeAndNil(FGE);
  FreeAndNil(FRegistry);
  FreeAndNil(FSystem);
  FreeAndNil(FKernel);
  FreeAndNil(FFiles);
  FMemory.Clear;
  FExecutable := TPSPExecutable.Load(FProgram.Executable, FMemory);
  if FExecutable.Entry = 0 then
    raise EPSPFormat.Create('PSP: main executable has no entry point');
  FModules := TObjectList<TPSPLoadedModule>.Create(True);
  var Root := TPSPLoadedModule.Create;
  Root.Id := $50;
  if FExecutable.LowAddress>=PSPUserBase then Root.Block:=$50;
  Root.Executable := FExecutable;
  Root.Started := True;
  Root.Path := FProgram.BootPath;
  FModules.Add(Root);
  FImports := Copy(FExecutable.Imports);
  // The root thread owns the top 64 KiB; other stacks use the kernel allocator.
  if FExecutable.HighAddress > PSPRAMBase + PSPRAMSize - $10000 then
    raise EPSPFormat.Create('PSP: executable overlaps the bootstrap stack');
  if Length(FExecutable.Imports) > $FFFFE then
    raise EPSPFormat.Create('PSP: too many HLE imports');
  for var I := 0 to High(FExecutable.Imports) do
  begin
    var Address := FExecutable.Imports[I].Address;
    FMemory.Write32(Address, $03E00008); // jr ra
    FMemory.Write32(Address + 4, (Cardinal(I + 1) shl 6) or $C);
  end;
  FCPU.Reset(FExecutable.Entry, PSPRAMBase + PSPRAMSize - $100, FExecutable.GP);
  FMemory.Fill(PSPRAMBase + PSPRAMSize - $10000, $10000, $FF);
  // Returning from the root context calls an explicit halt trampoline.
  FMemory.Write32(PSPThreadReturnTrampoline, $0000000C);
  FMemory.Write32(PSPThreadReturnTrampoline + 4, 0);
  FMemory.Write32(PSPCallbackReturnTrampoline, $0000000C);
  FCPU.Registers[31] := PSPThreadReturnTrampoline;
  if (FProgram.BootPath <> '') or (Length(FLaunchArguments) <> 0) then
  begin
    var Arguments := FLaunchArguments;
    if Length(Arguments) = 0 then
      Arguments := TEncoding.UTF8.GetBytes(FProgram.BootPath + #0);
    var Address := (PSPRAMBase + PSPRAMSize - $100 - Cardinal(Length(Arguments))) and $FFFFFFF0;
    FMemory.Load(Address, Arguments);
    FCPU.Registers[4] := Length(Arguments);
    FCPU.Registers[5] := Address;
    FCPU.Registers[29] := Address - $40;
  end;
  FKernel := TPSPKernel.Create(FMemory, FCPU, FExecutable);
  FFiles := TPSPFileSystem.Create(FStorage, FMemory, FCPU, FProgram, FKernel);
  FRegistry := TPSPRegistry.Create(FMemory, FCPU, FStorage);
  FSystem := TPSPSystemHLE.Create(FMemory, FCPU, FKernel, FProgram.MediaPath <> '');
  FGE := TPSPGE.Create(FMemory, FCPU, FKernel);
  SetRenderWorkerCount(FRenderWorkerCount);
  FAudio := TPSPAudio.Create(FMemory, FCPU, FKernel);
  FSAS := TPSPSAS.Create(FMemory, FCPU);
  FUtility := TPSPUtility.Create(FMemory, FCPU, FFiles);
  FATRAC := TPSPATRAC.Create(FMemory, FCPU, FKernel);
  FMP3 := TPSPMP3.Create(FMemory, FCPU, FKernel);
  FController := TPSPController.Create(FMemory, FCPU, FKernel);
  FMpeg := TPSPMpeg.Create(FMemory, FCPU, FKernel);
  FKernel.OnTime := Advance;
  FKernel.OnThreadExit := ModuleThreadExit;
  FKernel.ResolveGP := ModuleGP;
  FFramebuffer := 0;
  FStride := 512;
  FFormat := 3;
  FPendingDisplay := False;
  FDisplayModeSet := False;
  FDisplayHoldMode := 0;
  FHCountOffset := 0;
  FFrameNumber := 0;
  FLastVBlank := 0;
end;

procedure TPSPConsole.Syscall(CPU: TPSPCPU; Code: Cardinal);
begin
  if (Code = 0) and (CPU.CurrentPC = PSPCallbackReturnTrampoline) then
  begin
    FKernel.ReturnFromCall;
    Exit;
  end;
  if (Code = 0) and (CPU.CurrentPC = PSPThreadReturnTrampoline) then
  begin
    FKernel.ExitCurrent(CPU.Registers[2], False);
    Exit;
  end;
  if (Code = 0) or (Code > Cardinal(Length(FImports))) then
    raise EPSPInstruction.CreateFmt('PSP: unbound syscall %x at PC %.8x', [Code, CPU.CurrentPC]);
  CPU.Registers[2] := CallImport(FImports[Code - 1]);
end;

procedure TPSPConsole.LinkModules;
begin
  for var I := 0 to High(FImports) do
  begin
    var Import := FImports[I];
    var Target: Cardinal := 0;
    for var Module in FModules do
      if Module.NativeService = pspGuestModule then
        for var Symbol in Module.Executable.Symbols do
          if not Symbol.Variable and (Symbol.ModuleName = Import.ModuleName) and (Symbol.NID = Import.NID) then
            Target := Symbol.Address;
    if Target <> 0 then
    begin
      FMemory.Write32(Import.Address, $08000000 or ((Target shr 2) and $03FFFFFF));
      FMemory.Write32(Import.Address + 4, 0);
    end
    else
    begin
      FMemory.Write32(Import.Address, $03E00008);
      FMemory.Write32(Import.Address + 4, (Cardinal(I + 1) shl 6) or $C);
    end;
  end;
end;

function TPSPConsole.LastVideoPacket: TBytes;
begin
  Result := FMpeg.LastVideoPacket
end;

function TPSPConsole.ModuleGP(Address: Cardinal): Cardinal;
begin
  Address := Address and $3FFFFFFF;
  for var Module in FModules do
    if (Address >= Module.Executable.LowAddress) and (Address < Module.Executable.HighAddress) then
      Exit(Module.Executable.GP);
  Result := FExecutable.GP;
end;

procedure TPSPConsole.ModuleThreadExit(Id, Status: Cardinal);
begin
  for var Module in FModules do
  begin
    if Module.UnloadPending and
      (((Module.Thread=Id) and Module.Stopping) or ((Module.SelfUnloadThread=Id) and not Module.Stopping)) then
    begin
      if Module.SelfStatusPointer<>0 then
        if Module.Stopping then FMemory.Write32(Module.SelfStatusPointer,Status)
        else FMemory.Write32(Module.SelfStatusPointer,0);
      if Module.StatusPointer<>0 then FMemory.Write32(Module.StatusPointer,Module.SelfExitCode);
      var Caller:=Module.SelfUnloadThread;var ModuleId:=Module.Id;
      Module.SelfUnloadThread:=0;Module.Thread:=0;Module.UnloadPending:=False;
      if Caller<>Id then FKernel.TerminateDeleteThread(Caller,Module.SelfExitCode);
      var Error:=UnloadModule(Module);
      FKernel.CompleteDevice(3,ModuleId,Error);
      Exit;
    end;
    if (Module.Thread <> 0) and (Module.Thread = Id) then
    begin
      {$IFDEF PSP_TRACE_MODULES}
      Writeln('module exit ', Module.Executable.ModuleName, ' status=', IntToHex(Status, 8)); {$ENDIF}
      Module.Thread := 0;
      if Module.StatusPointer <> 0 then
        FMemory.Write32(Module.StatusPointer, Status);
      Module.StatusPointer:=0;
      var WasStopping := Module.Stopping;
      if Module.Stopping then
        Module.Started := False
      else
        Module.Started := Integer(Status) >= 0;
      Module.Stopping := False;
      if WasStopping then
        FKernel.CompleteDevice(3, Module.Id, 0)
      else
        FKernel.CompleteDevice(3, Module.Id, Module.Id);
      Break;
    end;
  end;
end;

function TPSPConsole.UnloadModule(Module: TPSPLoadedModule): Cardinal;
begin
  Result:=0;
  if Module.Block<>0 then
  begin
    Result:=FKernel.ReleaseModule(Module.Block);
    if Result<>0 then Exit;
  end;
  for var I:=High(FImports) downto 0 do
    if (FImports[I].Address>=Module.Executable.LowAddress) and
      (FImports[I].Address<Module.Executable.HighAddress) then Delete(FImports,I,1);
  FModules.Remove(Module);
  LinkModules;
end;

function TPSPConsole.SelfStopUnload(ExitCode, ArgSize, ArgPointer, StatusPointer, Options: Cardinal): Cardinal;
begin
  if (StatusPointer<>0) and not FMemory.IsValid(StatusPointer,4) then Exit($800200D3);
  if Options<>0 then
  begin
    if not FMemory.IsValid(Options,20) then Exit($800200D3);
    if FMemory.Read32(Options)<20 then Exit($800200D2);
  end;
  var Module:TPSPLoadedModule:=nil;
  for var Item in FModules do if Item.Id=FKernel.CurrentModuleId then Module:=Item;
  if Module=nil then Exit($8002012E);
  {$IFDEF PSP_TRACE_MODULES}
  Writeln('self unload ',Module.Executable.ModuleName,' uid=',IntToHex(Module.Id,8),' thread=',IntToHex(FKernel.CurrentThreadId,8));
  {$ENDIF}
  if Module.UnloadPending or Module.Stopping or
    ((Module.Thread<>0) and (Module.Thread<>FKernel.CurrentThreadId)) then Exit($80020133);
  var Entry:Cardinal:=0;var Priority:Cardinal:=32;var StackSize:Cardinal:=$40000;var Attributes:Cardinal:=0;
  var KernelMemory:=Module.Executable.Attributes and $1000<>0;
  if KernelMemory then StackSize:=$1000;
  for var Symbol in Module.Executable.Symbols do
    if Symbol.ModuleName='' then
      if not Symbol.Variable and (Symbol.NID=$CEE8593C) then Entry:=Symbol.Address
      else if Symbol.Variable and (Symbol.NID=$CF0CC697) then
      begin
        if FMemory.Read32(Symbol.Address+4)<>0 then Priority:=FMemory.Read32(Symbol.Address+4);
        if FMemory.Read32(Symbol.Address+8)<>0 then StackSize:=FMemory.Read32(Symbol.Address+8);
        Attributes:=FMemory.Read32(Symbol.Address+12);
      end;
  if Options<>0 then
  begin
    if FMemory.Read32(Options+8)<>0 then StackSize:=FMemory.Read32(Options+8);
    if FMemory.Read32(Options+12)<>0 then Priority:=FMemory.Read32(Options+12);
    Attributes:=FMemory.Read32(Options+16);
  end;
  var StopThread:Cardinal:=0;
  if Entry<>0 then
  begin
    if (ArgSize<>0) and not FMemory.IsValid(ArgPointer,ArgSize) then Exit($800200D3);
    StopThread:=FKernel.StartModule(Entry,Module.Executable.GP,ArgSize,ArgPointer,Priority,StackSize,Attributes,KernelMemory,Module.Id);
    if StopThread and $80000000<>0 then Exit(StopThread);
  end;
  Module.UnloadPending:=True;
  Module.SelfUnloadThread:=FKernel.CurrentThreadId;
  Module.SelfExitCode:=ExitCode;
  Module.SelfStatusPointer:=StatusPointer;
  if StopThread<>0 then
  begin
    Module.Thread:=StopThread;Module.Stopping:=True;
    FKernel.WaitDevice(3,Module.Id);
  end
  else
  begin
    if StatusPointer<>0 then FMemory.Write32(StatusPointer,0);
    FKernel.ExitCurrent(ExitCode,True);
  end;
  Result:=0;
end;

function TPSPConsole.ModuleCall(NID: Cardinal; out Value: Cardinal): Boolean;
begin
  Result := True;
  Value := 0;
  var A := FCPU.Registers[4];
  var B := FCPU.Registers[5];
  var C := FCPU.Registers[6];
  var D := FCPU.Registers[7];
  var Module: TPSPLoadedModule := nil;
  for var Item in FModules do
    if Item.Id = A then
      Module := Item;
  case NID of
    $D675EBB8,$CC1D3699:Value:=SelfStopUnload(A,B,C,0,0);
    $8F2DF740:Value:=SelfStopUnload(A,B,C,D,FCPU.Registers[8]);
    $977DE386, $B7F46618:
      begin
        var Path: string;
        var ProgramData: TPSPProgram;
        if NID = $B7F46618 then
        begin
          Path := 'fd:' + IntToStr(A);
          Value := FFiles.ReadProgram(A, ProgramData);
          if Value <> 0 then
            Exit;
        end
        else
        begin
          Path := FMemory.ReadString(A, 1024);
          try
            ProgramData := FFiles.ReadProgram(Path)
          except
            on EFOpenError do
            begin
              Value := $80010002;
              Exit
            end
          end;
        end;
        {$IFDEF PSP_TRACE_MODULES}                 Writeln('load module ', Path); {$ENDIF}
        var Data := ProgramData.Executable;
        if (Length(Data) < 52) or (PSPLE16(Data, 16) <> $FFA0) then
          raise EPSPFormat.Create('PSP: dynamic module requires relocatable PRX');
        var Headers := PSPLE32(Data, 28);
        var Count := PSPLE16(Data, 44);
        if UInt64(Headers) + UInt64(Count) * 32 > UInt64(Length(Data)) then
          raise EPSPFormat.Create('PSP: invalid dynamic module header');
        var Span: UInt64 := 0;
        for var I := 0 to Integer(Count) - 1 do
        begin
          var Header := Headers + Cardinal(I) * 32;
          if PSPLE32(Data, Header) = 1 then
            Span := Max(Span, UInt64(PSPLE32(Data, Header + 8)) + PSPLE32(Data, Header + 20));
        end;
        if (Span = 0) or (Span > PSPRAMSize) then
          raise EPSPFormat.Create('PSP: invalid module memory size');
        var Address: Cardinal;
        var ModuleOffset := PSPLE32(Data, Headers + 12) and $7FFFFFFF;
        var KernelMemory := PSPLE16(Data, ModuleOffset) and $1000 <> 0;
        var Block := FKernel.ReserveModule(Cardinal(Span), Address, KernelMemory);
        if Block and $80000000 <> 0 then
        begin
          Value := Block;
          Exit;
        end;
        var Loaded := TPSPLoadedModule.Create;
        try
          Loaded.Block := Block;
          Loaded.Id := Block;
          Loaded.Path := Path;
          Loaded.Executable := TPSPExecutable.Load(Data, FMemory, Address);
          // RetroMul owns SAS rendering; the firmware PRX's Media Engine driver
          // is replaced by this native service, including module initialization.
          if Loaded.Executable.ModuleName = 'sceSAScore' then
            Loaded.NativeService := pspNativeSAS;
          if Loaded.Executable.ModuleName = 'sceATRAC3plus_Library' then
            Loaded.NativeService := pspNativeATRAC;
          if Loaded.Executable.ModuleName = 'sceMpeg_library' then
            Loaded.NativeService := pspNativeMpeg;
          if SameText(Loaded.Executable.ModuleName, 'sceMp3_Library') then
            Loaded.NativeService := pspNativeMP3;
          if Length(FImports) + Length(Loaded.Executable.Imports) > $FFFFE then
            raise EPSPFormat.Create('PSP: too many module imports');
          FImports := FImports + Loaded.Executable.Imports;
          FModules.Add(Loaded);
        except
          Loaded.Free;
          FKernel.ReleaseModule(Block);
          raise;
        end;
        LinkModules;
        Value := Block;
        {$IFDEF PSP_TRACE_MODULES}                 Writeln('loaded ', Loaded.Executable.ModuleName, ' uid=', Block, ' entry=', IntToHex(Loaded.Executable.Entry, 8), ' gp=', IntToHex(Loaded.Executable.GP, 8)); {$ENDIF}
      end;
    $50F0C1EC, $D1FF982A:
      begin
        {$IFDEF PSP_TRACE_MODULES}
        Writeln('module start/stop ', IntToHex(NID, 8), ' uid=', A, ' status=', IntToHex(D, 8)); {$ENDIF}
        if Module = nil then
        begin
          Value := $8002012E;
          Exit;
        end;
        if Module.Thread <> 0 then
        begin
          Value := $80020133;
          Exit;
        end;
        if (D <> 0) and not FMemory.IsValid(D, 4) then
        begin
          Value := $800200D3;
          Exit;
        end;
        var Stopping := NID = $D1FF982A;
        if Module.Started <> Stopping then
        begin
          Value := $80020133;
          Exit;
        end;
        if Module.NativeService <> pspGuestModule then
        begin
          if not Stopping then
          begin
            case Module.NativeService of
              pspNativeSAS:
                begin
                  FSAS.Free;
                  FSAS := TPSPSAS.Create(FMemory, FCPU);
                end;
              pspNativeATRAC:
                begin
                  FATRAC.Free;
                  FATRAC := TPSPATRAC.Create(FMemory, FCPU, FKernel);
                end;
              pspNativeMpeg:
                begin
                  FMpeg.Free;
                  FMpeg := TPSPMpeg.Create(FMemory, FCPU, FKernel)
                end;
              pspNativeMP3:
                begin
                  FMP3.Free;
                  FMP3 := TPSPMP3.Create(FMemory, FCPU, FKernel);
                end;
            end;
          end;
          Module.Started := not Stopping;
          if D <> 0 then
            FMemory.Write32(D, 0);
          Value := Module.Id;
          if Stopping then
            Value := 0;
          Exit;
        end;
        var Entry: Cardinal := 0;
        var EntryNID: Cardinal := $D632ACDB;
        if Stopping then
          EntryNID := $CEE8593C;
        var Priority: Cardinal := 32;
        var StackSize: Cardinal := $40000;
        var KernelMemory := Module.Executable.Attributes and $1000 <> 0;
        if KernelMemory then
          StackSize := $1000;
        var Attributes: Cardinal := 0;
        for var Symbol in Module.Executable.Symbols do
        begin
          if (Symbol.ModuleName = '') and not Symbol.Variable and (Symbol.NID = EntryNID) then
            Entry := Symbol.Address;
          if (Symbol.ModuleName = '') and Symbol.Variable and
            (((not Stopping) and (Symbol.NID = $0F7C276C)) or (Stopping and (Symbol.NID = $CF0CC697))) then
          begin
            if FMemory.Read32(Symbol.Address + 4) <> 0 then
              Priority := FMemory.Read32(Symbol.Address + 4);
            if FMemory.Read32(Symbol.Address + 8) <> 0 then
              StackSize := FMemory.Read32(Symbol.Address + 8);
            Attributes := FMemory.Read32(Symbol.Address + 12);
          end;
        end;
        if not Stopping and (Entry = 0) then
          Entry := Module.Executable.Entry;
        var Options := FCPU.Registers[8];
        if Options <> 0 then
        begin
          if FMemory.Read32(Options) < 20 then
          begin
            Value := $800200D2;
            Exit;
          end;
          if FMemory.Read32(Options + 8) <> 0 then
            StackSize := FMemory.Read32(Options + 8);
          if FMemory.Read32(Options + 12) <> 0 then
            Priority := FMemory.Read32(Options + 12);
          Attributes := FMemory.Read32(Options + 16);
        end;
        if Entry = 0 then
        begin
          Module.Started := not Stopping;
          if D <> 0 then
            FMemory.Write32(D, 0);
          Value := Module.Id;
          if Stopping then
            Value := 0;
          Exit;
        end;
        {$IFDEF PSP_TRACE_MODULES}                 Writeln('start entry=', IntToHex(Entry, 8), ' priority=', Priority, ' stack=', IntToHex(StackSize, 8)); {$ENDIF}
        Value := FKernel.StartModule(Entry, Module.Executable.GP, B, C, Priority, StackSize, Attributes, KernelMemory,Module.Id);
        if Value and $80000000 <> 0 then
          Exit;
        Module.Thread := Value;
        Module.StatusPointer := D;
        Module.Stopping := Stopping;
        FKernel.WaitDevice(3, Module.Id);
        Value := Module.Id;
      end;
    $2E0911AA:
      begin
        if Module = nil then
        begin
          Value := $8002012E;
          Exit;
        end;
        if Module.Started or (Module.Thread <> 0) then
        begin
          Value := $80020133;
          Exit;
        end;
        Value := UnloadModule(Module);
      end;
    $D8B73127, $F0A26395:
      begin
        if NID=$F0A26395 then
        begin
          Value:=$8002012E;
          for var Item in FModules do if Item.Id=FKernel.CurrentModuleId then Value:=Item.Id;
          Exit;
        end;
        var Address := A;
        Address:=Address and $3FFFFFFF;
        Value := $8002012E;
        for var Item in FModules do
          if (Address >= Item.Executable.LowAddress) and (Address < Item.Executable.HighAddress) then
            Value := Item.Id;
      end;
  else
    Result := False;
  end;
end;

procedure TPSPConsole.Advance(Time: UInt64);
begin
  FFiles.Advance(Time);
  FController.Advance(Time, FInput);
  if Time div 16683 > FLastVBlank then
  begin
    FLastVBlank := Time div 16683;
    FKernel.RaiseInterrupt(30);
  end;
end;

function TPSPConsole.CallImport(const Import: TPSPImport): Cardinal;
begin
  if (Import.ModuleName = 'sceMp3') and FMP3.Handle(Import.NID, Result) then Exit;
  if (Import.ModuleName = 'sceMpeg') and FMpeg.Handle(Import.NID, Result) then
    Exit;
  if (Import.ModuleName = 'sceAudio') and FAudio.Handle(Import.NID, Result) then
    Exit;
  if (Import.ModuleName = 'sceCtrl') and FController.Handle(Import.NID, FInput, Result) then
    Exit;
  if ((Import.ModuleName = 'sceAtrac3plus') or (Import.ModuleName = 'sceATRAC3plus_Library')) and FATRAC.Handle(Import.NID, Result) then
    Exit;
  if (Import.ModuleName = 'sceUtility') and FUtility.Handle(Import.NID, Result) then
    Exit;
  if (Import.ModuleName = 'sceSasCore') and FSAS.Handle(Import.NID, Result) then
    Exit;
  if (Import.ModuleName = 'sceGe_user') and FGE.Handle(Import.NID, Result) then
    Exit;
  if ((Import.ModuleName = 'ModuleMgrForUser') or (Import.ModuleName = 'ModuleMgrForKernel')) and ModuleCall(Import.NID, Result) then
    Exit;
  if (Import.ModuleName = 'ThreadManForKernel') and FKernel.Handle('ThreadManForKernel', Import.NID, Result) then
    Exit;
  if (Import.ModuleName = 'InterruptManagerForKernel') and FKernel.Handle('Kernel_Library', Import.NID, Result) then
    Exit;
  if FKernel.Handle(Import.ModuleName, Import.NID, Result) then
  begin
    {$IFDEF PSP_TRACE_SYNC}
    if Result and $80000000 <> 0 then
      Writeln('kernel ', Import.ModuleName, ' ', IntToHex(Import.NID, 8), ' a=', IntToHex(FCPU.Registers[4], 8), ' result=', IntToHex(Result, 8));
    {$ENDIF}
    Exit;
  end;
  if (Import.ModuleName = 'sceReg') and FRegistry.Handle(Import.NID, Result) then
    Exit;
  if FSystem.Handle(Import.ModuleName, Import.NID, Result) then
    Exit;
  if (Import.ModuleName = 'IoFileMgrForUser') and FFiles.Handle(Import.NID, Result) then
    Exit;
  if Import.ModuleName = 'StdioForUser' then
    case Import.NID of
      $172D316E:
        Exit(0);
      $A6BAB2E9:
        Exit(1);
      $F78BA90A:
        Exit(2);
    end;
  var A := FCPU.Registers[4];
  var B := FCPU.Registers[5];
  var C := FCPU.Registers[6];
  var D := FCPU.Registers[7];
  if (Import.ModuleName = 'sceDmac') and ((Import.NID = $617F3FE6) or (Import.NID = $D97F94D8)) then
  begin
    if C = 0 then
      Exit($80000104);
    if not FMemory.IsValid(A, C) or not FMemory.IsValid(B, C) then
      Exit($80000103);
    FMemory.CopyMemory(A, B, C);
    if C >= 272 then
      FKernel.WaitUntil(FKernel.Time + C div 236);
    Exit(0);
  end;
  if Import.ModuleName = 'SysclibForKernel' then
    case Import.NID of
      $AB7592FF, $A48D2592:
        begin
          FMemory.CopyMemory(A, B, C);
          Exit(A);
        end;
      $10F3BB61:
        begin
          FMemory.Fill(A, C, Byte(B and $FF));
          Exit(A);
        end;
      $52DF196C:
        Exit(Cardinal(Length(FMemory.ReadString(A, PSPRAMSize))));
      $90C5573D:
        Exit(Cardinal(Length(FMemory.ReadString(A, B))));
      $B49A7697:
        begin
          var Ended := False;
          var I: Cardinal := 0;
          while I < C do
          begin
            var V: Byte := 0;
            if not Ended then
              V := FMemory.Read8(B + I);
            if V = 0 then
              Ended := True;
            FMemory.Write8(A + I, V);
            Inc(I);
          end;
          Exit(A);
        end;
      $C0AB8932, $7AB35214, $81D0D1F7:
        begin
          var Limit := C;
          if Import.NID = $C0AB8932 then
            Limit := PSPRAMSize;
          var I: Cardinal := 0;
          while I < Limit do
          begin
            var Left := FMemory.Read8(A + I);
            var Right := FMemory.Read8(B + I);
            if Left <> Right then
              Exit(Cardinal(Integer(Left) - Integer(Right)));
            if (Left = 0) and (Import.NID <> $81D0D1F7) then
              Exit(0);
            Inc(I);
          end;
          Exit(0);
        end;
      $EC6F1CF2, $476FD94A:
        begin
          var Offset: Cardinal := 0;
          if Import.NID = $476FD94A then
            Offset := Length(FMemory.ReadString(A, PSPRAMSize));
          var I: Cardinal := 0;
          var V: Byte;
          repeat
            V := FMemory.Read8(B + I);
            FMemory.Write8(A + Offset + I, V);
            Inc(I);
          until V = 0;
          Exit(A);
        end;
    end;
  if Import.ModuleName = 'sceGe_user' then
    case Import.NID of
      $E47E40E4:
        Exit(PSPVRAMBase);
      $1F6752AD:
        Exit(PSPVRAMSize);
    end;
  if (Import.ModuleName = 'sceSuspendForUser') and (Import.NID = $3AEE7261) then
  begin
    if A <> 0 then
      Exit($80000107);
    Exit(0); // Host power management is independent of guest power locks.
  end;
  if (Import.ModuleName = 'UtilsForUser') and (Import.NID = $6AD345D7) then
    Exit(0); // PSP GPIO output latch has no attached external device.
  if Import.ModuleName = 'sceDisplay' then
    case Import.NID of
      $7ED59BC4:
        begin
          FDisplayHoldMode := A;
          Exit(0);
        end;
      $0E20F177:
        begin
          if A <> 0 then
            Exit($80000107);
          if (B <> 480) or (C <> 272) then
            Exit($80000104);
          FDisplayModeSet := True;
          Exit(0);
        end;
      $289D82FE:
        begin
          if (D > 1) or (C > 3) then
            Exit($80000107);
          if A <> 0 then
          begin
            if (B < 480) or (B > 2048) or (B and 63 <> 0) or (A and 15 <> 0) then
              Exit($80000104);
            var BytesPerPixel: Cardinal := 2;
            if C = 3 then
              BytesPerPixel := 4;
            if not FMemory.IsValid(A, (B * 271 + 480) * BytesPerPixel) then
              Exit($800200D3);
          end;
          if D = 1 then
          begin
            FPendingFramebuffer := A;
            FPendingStride := B;
            FPendingFormat := C;
            FPendingDisplay := True;
          end
          else
          begin
            FFramebuffer := A;
            FStride := B;
            FFormat := C;
          end;
          Exit(0);
        end;
      $EEDA2E54:
        begin
          if D > 1 then
            Exit($80000107);
          var Address := FFramebuffer;
          var Stride := FStride;
          var PixelFormat := FFormat;
          if (D = 1) and FPendingDisplay then
          begin
            Address := FPendingFramebuffer;
            Stride := FPendingStride;
            PixelFormat := FPendingFormat;
          end;
          if A <> 0 then
            FMemory.Write32(A, Address);
          if B <> 0 then
            FMemory.Write32(B, Stride);
          if C <> 0 then
            FMemory.Write32(C, PixelFormat);
          Exit(0);
        end;
      $4D4E10EC:
        Exit(Ord(FKernel.Time mod 16683 < 770));
      $B4F378FA:
        Exit(Ord(FDisplayModeSet and (FFramebuffer <> 0)));
      $DEA197D4:
        begin
          if A <> 0 then
            FMemory.Write32(A, 0);
          if B <> 0 then
            FMemory.Write32(B, 480);
          if C <> 0 then
            FMemory.Write32(C, 272);
          Exit(0);
        end;
      $DBA6C4C4:
        begin
          FCPU.SetFloatResult(59.9400599);
          Exit(0);
        end;
      $773DD3A3:
        Exit(Cardinal((FKernel.Time mod 16683) * 286 div 16683));
      $210EAB3A:
        Exit(Cardinal((Int64(FKernel.Time * 286 div 16683) + FHCountOffset) and $FFFFFFFF));
      $A83EF139:
        begin
          if Integer(A) < 0 then
            Exit($800001FE);
          FHCountOffset := Int64(A) - Int64(FKernel.Time * 286 div 16683);
          Exit(0);
        end;
      $984C27E7, $36CDFADE, $46F186C3, $8EB9EC49, $40F1469C, $77ED8B3A:
        begin
          if not FKernel.DispatchEnabled then
            Exit($800201A7);
          var Count: Cardinal := 1;
          if (Import.NID = $40F1469C) or (Import.NID = $77ED8B3A) then
          begin
            if Integer(A) <= 0 then
              Exit($800001FE);
            Count := A;
          end;
          if ((Import.NID = $36CDFADE) or (Import.NID = $8EB9EC49)) and (FKernel.Time mod 16683 < 770) then
            Exit(1);
          FKernel.WaitUntil(((FKernel.Time div 16683) + Count) * 16683);
          if (Import.NID = $46F186C3) or (Import.NID = $8EB9EC49) or (Import.NID = $77ED8B3A) then
            FKernel.AcceptCallbacks;
          Exit(0);
        end;
      $9C6EAAD7:
        Exit(Cardinal(FFrameNumber and $FFFFFFFF));
    end;
  if (Import.ModuleName = 'LoadExecForUser') and (Import.NID = $BD2F1094) then
  begin
    if A = 0 then
      Exit($8002014C);
    var Path := FMemory.ReadString(A, 1024);
    var Arguments: TBytes;
    if B <> 0 then
    begin
      if not FMemory.IsValid(B, 16) or (FMemory.Read32(B) < 16) then
        Exit($8002014B);
      var Count := FMemory.Read32(B + 4);
      var Address := FMemory.Read32(B + 8);
      if (Count > $E000) or ((Count <> 0) and not FMemory.IsValid(Address, Count)) then
        Exit($8002014B);
      Arguments := FMemory.ReadBytes(Address, Count);
    end;
    var ProgramData: TPSPProgram;
    try
      ProgramData := FFiles.ReadProgram(Path);
      // Check the full loader, including imports/relocations, before stopping
      // the old kernel. A bad target must leave the current process runnable.
      var ValidationMemory := TPSPMemory.Create;
      try
        TPSPExecutable.Load(ProgramData.Executable, ValidationMemory)
      finally
        ValidationMemory.Free
      end;
    except
      on EFOpenError do
        Exit($80010002);
      on EPSPFormat do
        Exit($80020148);
      on EPSPMemory do
        Exit($80020148);
    end;
    FNextProgram := FProgram;
    FNextProgram.Executable := ProgramData.Executable;
    FNextProgram.BootPath := ProgramData.BootPath;
    FLaunchArguments := Arguments;
    FLoadExecPending := True;
    FKernel.StopScheduling;
    Exit(0);
  end;
  if Import.ModuleName = 'LoadExecForUser' then
    if Import.NID = $05572A5F then
    begin
      FCPU.Halt;
      Exit(0);
    end;
  if (Import.ModuleName = 'UtilsForUser') or (Import.ModuleName = 'UtilsForKernel') then
    case Import.NID of
      $79D1C3FA, $B435DEC5, $3EE30821, $34B9FA9E:
        Exit(0); // Coherent interpreter memory; no host cache work required.
    end;
  raise EPSPInstruction.CreateFmt('PSP: unimplemented HLE %s NID %.8x at PC %.8x', [Import.ModuleName, Import.NID, FCPU.CurrentPC]);
end;

function Expand5(Value: Cardinal): Cardinal; inline;
begin
  Result := (Value shl 3) or (Value shr 2);
end;

{$POINTERMATH ON}
procedure TPSPConsole.Render(out Frame: TEmulatorFrame);
begin
  Frame := Default(TEmulatorFrame);
  Frame.Width := PSPFrameWidth;
  Frame.Height := PSPFrameHeight;
  Frame.FrameNumber := FFrameNumber;
  Frame.FramesPerSecond := PSPFrameRate;
  SetLength(Frame.Pixels, PSPFrameWidth * PSPFrameHeight);
  if FFramebuffer = 0 then
  begin
    for var I := 0 to High(Frame.Pixels) do
      Frame.Pixels[I] := TAlphaColor($FF000000);
    Exit;
  end;
  // SetFrameBuf validates this entire span, including row padding. Resolve
  // the guest mapping once, then convert contiguous host rows. No guest
  // pointer escapes the memory bus and no checks are repeated per pixel.
  var BytesPerPixel: Cardinal := 2;
  if FFormat = 3 then
    BytesPerPixel := 4;
  var Data := FMemory.ReadBytes(FFramebuffer, ((PSPFrameHeight - 1) * FStride + PSPFrameWidth) * BytesPerPixel);
  var Destination := PCardinal(@Frame.Pixels[0]);
  for var Y := 0 to PSPFrameHeight - 1 do
  begin
    if FFormat = 3 then
    begin
      var Source := PCardinal(@Data[Cardinal(Y) * FStride * 4]);
      for var X := 0 to PSPFrameWidth - 1 do
      begin
        var V := Source[X];
        Destination[X] := $FF000000 or ((V and $FF) shl 16) or (V and $FF00) or ((V shr 16) and $FF);
      end;
    end
    else
    begin
      var Source := PWord(@Data[Cardinal(Y) * FStride * 2]);
      for var X := 0 to PSPFrameWidth - 1 do
      begin
        var V := Cardinal(Source[X]);
        var R, G, B: Cardinal;
        case FFormat of
          0:
            begin
              R := Expand5(V and 31);
              G := (V shr 5) and 63;
              G := (G shl 2) or (G shr 4);
              B := Expand5((V shr 11) and 31)
            end;
          1:
            begin
              R := Expand5(V and 31);
              G := Expand5((V shr 5) and 31);
              B := Expand5((V shr 10) and 31)
            end;
        else
          R := (V and 15) * 17;
          G := ((V shr 4) and 15) * 17;
          B := ((V shr 8) and 15) * 17
        end;
        Destination[X] := $FF000000 or (R shl 16) or (G shl 8) or B;
      end;
    end;
    Inc(Destination, PSPFrameWidth);
  end;
end;

procedure TPSPConsole.RunFrame(out Frame: TEmulatorFrame);
begin
  if FLoadExecPending then
  begin
    FProgram := FNextProgram;
    Reset
  end;
  FUtility.Update(FInput);
  // Cover a complete frame even if the guest switches to 333 MHz mid-frame.
  // RunUntil stops at its deadline; this is a runaway guard, not CPU throttling.
  {$IFDEF PSP_PROFILE}var ProfileStarted:=PSPProfileStart;{$ENDIF}
  FKernel.RunUntil((FFrameNumber + 1) * 16683, 16683 * 333 + 10000);
  {$IFDEF PSP_PROFILE}PSPProfileEnd(TPSPProfilePart.Kernel,ProfileStarted);{$ENDIF}
  if FLoadExecPending then
  begin
    Render(Frame);
    Exit
  end;
  FGE.Update;
  {$IFDEF PSP_PROFILE}ProfileStarted:=PSPProfileStart;{$ENDIF}
  FAudioSamples := FAudio.Render;
  {$IFDEF PSP_PROFILE}PSPProfileEnd(TPSPProfilePart.AudioOutput,ProfileStarted);{$ENDIF}
  Inc(FFrameNumber);
  if FPendingDisplay then
  begin
    FFramebuffer := FPendingFramebuffer;
    FStride := FPendingStride;
    FFormat := FPendingFormat;
    FPendingDisplay := False;
  end;
  {$IFDEF PSP_PROFILE}ProfileStarted:=PSPProfileStart;{$ENDIF}
  Render(Frame);
  FUtility.Render(Frame);
  {$IFDEF PSP_PROFILE}PSPProfileEnd(TPSPProfilePart.Display,ProfileStarted);{$ENDIF}
end;

end.

