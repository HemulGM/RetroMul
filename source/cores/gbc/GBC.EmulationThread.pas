unit GBC.EmulationThread;

interface

uses
  GB.EmulationThread, GB.GPU, GB.ROM, GB.MBC, GB.Memory, GB.Joypad, GB.Timer,
  GB.InterruptManager;

type
  TGBInputEvent = GB.EmulationThread.TGBInputEvent;

  TGBCEmulationThread = class(TGBEmulationThread)
  protected
    function CoreID: string; override;
    function CreateVideo(ROM: TGBROM): TGBVideo; override;
    function CreateMemory(MBC: TGBMBC; Video: TGBVideo): TGBMemory; override;
    function GetJoypad: TGBJoypad; override;
    function GetTimer: TGBTimer; override;
    function GetInterruptManager: TGBInterruptManager; override;
    procedure ReleasePeripherals; override;
  end;

implementation

uses
  GBC.GPU, GBC.Memory, GBC.Joypad, GBC.Timer, GBC.InterruptManager;

function TGBCEmulationThread.CoreID: string;
begin
  Result := 'GBC';
end;

function TGBCEmulationThread.CreateVideo(ROM: TGBROM): TGBVideo;
begin
  var Video := TGBCGPU.Create(PublishFrame);
  Video.SetCGBMode(ROM.Cartridge.SupportsCGB);
  Result := Video;
end;

function TGBCEmulationThread.CreateMemory(MBC: TGBMBC; Video: TGBVideo): TGBMemory;
begin
  Result := TGBCMemory.Create(MBC, Video as TGBCGPU);
end;

function TGBCEmulationThread.GetJoypad: TGBJoypad;
begin
  Result := TGBCJoypad.Instance;
end;

function TGBCEmulationThread.GetTimer: TGBTimer;
begin
  Result := TGBCTimer.Instance;
end;

function TGBCEmulationThread.GetInterruptManager: TGBInterruptManager;
begin
  Result := TGBCInterruptManager.Instance;
end;

procedure TGBCEmulationThread.ReleasePeripherals;
begin
  TGBCJoypad.ReleaseInstance;
  TGBCTimer.ReleaseInstance;
  TGBCInterruptManager.ReleaseInstance;
end;

end.

