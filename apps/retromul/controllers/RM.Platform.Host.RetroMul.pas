unit RM.platform.Host.RetroMul;

{$I ..\RM.Mobile.inc}

interface

uses
  RM.Main, RM.Platform.Host;

function CreateRetroMulPlatformHost(View: TFormMain): IPlatformHost;

implementation

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes,
  System.Generics.Collections, FMX.Forms, FMX.Controls, FMX.Objects, FMX.Dialogs,
  FMX.Types, FMX.Platform, FMXInput, FMX.OpenDialog, Core.Emulation,
  Core.InputConfig, Core.Storage.Types, RM.Main.State, RM.Dialogs, RM.Gamepad,
  RM.Input, RM.Input.Gamepads, RM.Input.Runtime;

type
  IHostData = interface
    ['{20F8EF2E-3D04-48EC-B260-EDA09CF2D328}']
    function Values: TDictionary<string, IInterface>;
  end;

  THostData = class(TInterfacedObject, IHostData)
  private
    FValues: TDictionary<string, IInterface>;
  public
    constructor Create;
    destructor Destroy; override;
    function Values: TDictionary<string, IInterface>;
  end;

  TRetroMulPlatformHost = class(TInterfacedObject, IPlatformHost, IPlatformInput, IPlatformVideo, IFmxPlatformSurface, IPlatformDocuments)
  private
    // The form owns all state and controls. Asynchronous work uses CallbackAlive.
    FView: TFormMain;
    FState: TMainState;
    function GetCore: IEmulationCore;
    function GetSystemId: string;
    function GetStorage: IStorage;
    function GetActivity: TPlatformActivity;
    function GetInput: IPlatformInput;
    function GetVideo: IPlatformVideo;
    function GetData(const Key: string): IInterface;
    procedure SetData(const Key: string; const Value: IInterface);
    procedure ResetGame;
    procedure SetStatus(const Text: string);
    procedure ShowMessage(const Text: string; IsError: Boolean);
    function GetPorts: TCoreInputPorts;
    procedure SetPorts(const Ports: TCoreInputPorts);
    function GetHasInputSource: Boolean;
    function GetBindings: TArray<TInputBinding>;
    function GetValues: TArray<TInputValue>;
    function IsActionPressed(Action: Integer): Boolean;
    function ActionAmount(Action: Integer): Single;
    function DigitalAnalogAmount(Action: Integer; Pressed: Boolean): Single;
    procedure ClearCachedInput;
    procedure RequestInputUpdate(SubmitToCore: Boolean);
    function TryLocalToFrame(const Point: TPointF; out Pixel: TPoint): Boolean;
    function TryScreenToFrame(const Point: TPointF; out Pixel: TPoint): Boolean;
    function TryPointerToFrame(out Pixel: TPoint): Boolean;
    function GetPointerCaptured: Boolean;
    procedure SetPointerCaptured(Value: Boolean);
    procedure SetPointerInputEnabled(Enabled, ShowFocus: Boolean);
    procedure FitFrame;
    function GetInputForm: TCommonCustomForm;
    function GetContent: TControl;
    function GetFrameLayer: TImage;
    function GetGamepad: TScreenGamepad;
    function GetUsableSize: TSizeF;
    function GetBottomInset: Single;
    procedure OpenDocument(const Request: TPlatformDocumentRequest; const Selected: TPlatformDocumentAction);
    procedure SaveDocument(const Request: TPlatformDocumentRequest; const Write: TPlatformDocumentAction);
  public
    constructor Create(View: TFormMain);
  end;

constructor THostData.Create;
begin
  inherited;
  FValues := TDictionary<string, IInterface>.Create;
end;

destructor THostData.Destroy;
begin
  FValues.Free;
  inherited;
end;

function THostData.Values: TDictionary<string, IInterface>;
begin
  Result := FValues;
end;

function CreateRetroMulPlatformHost(View: TFormMain): IPlatformHost;
begin
  Result := TRetroMulPlatformHost.Create(View);
end;

constructor TRetroMulPlatformHost.Create(View: TFormMain);
begin
  inherited Create;
  FView := View;
  FState := View.State;
end;

function TRetroMulPlatformHost.GetCore: IEmulationCore;
begin
  Result := FState.Session.Emulation;
end;

function TRetroMulPlatformHost.GetSystemId: string;
begin
  Result := FState.Input.SystemId;
end;

function TRetroMulPlatformHost.GetStorage: IStorage;
begin
  Result := FState.Session.Storage;
end;

function TRetroMulPlatformHost.GetActivity: TPlatformActivity;
begin
  Result := Default(TPlatformActivity);
  var Core := GetCore;
  if FState.Session.OpeningRom then
    Result.Phase := TPlatformSessionPhase.Loading
  else if FState.Session.EmulationFaulted then
    Result.Phase := TPlatformSessionPhase.Failed
  else if Core = nil then
    Result.Phase := TPlatformSessionPhase.Empty
  else if FState.Session.UserPaused or FState.Session.AutoPaused or Core.IsPaused then
    Result.Phase := TPlatformSessionPhase.Paused
  else
    Result.Phase := TPlatformSessionPhase.Running;
  Result.SettingsOpen := FState.Settings.View <> nil;
  Result.GameplayVisible := (Core <> nil) and not FState.Browser.ViewingLibrary and
    not Result.SettingsOpen and (FState.Help.View = nil);
  var DialogOpen := RetroDialogVisible(FView);
  Result.CanShowGameNotice := Result.GameplayVisible and not DialogOpen and
    (Result.Phase in [TPlatformSessionPhase.Running, TPlatformSessionPhase.Paused]);
  Result.PeripheralInputBlocked := DialogOpen or FView.GameActionsPopup.IsOpen



    {$IFDEF ISMOBILE} or FState.Mobile.InBackground{$ENDIF};
  Result.AcceptsGameInput := Result.GameplayVisible and FView.HostInputHasFocus and
    not FState.Session.Reporting and not Result.PeripheralInputBlocked and
    (Result.Phase = TPlatformSessionPhase.Running);
  Result.VirtualControlsEnabled := (Core <> nil) and not FState.Session.EmulationFaulted and
    not FState.Session.OpeningRom and not FState.Session.UserPaused and
    not FState.Session.AutoPaused and not FState.Session.Reporting;
  Result.ShowVirtualGamepad := FState.Preferences.VirtualGamepadVisibility = TVirtualGamepadVisibility.Show;
  {$IFDEF ISMOBILE}
  if FState.Preferences.VirtualGamepadVisibility = TVirtualGamepadVisibility.Automatic then
    Result.ShowVirtualGamepad := FState.Input.PrimarySourceId = '';
  {$ENDIF}
end;

function TRetroMulPlatformHost.GetInput: IPlatformInput;
begin
  Result := Self;
end;

function TRetroMulPlatformHost.GetVideo: IPlatformVideo;
begin
  Result := Self;
end;

function TRetroMulPlatformHost.GetData(const Key: string): IInterface;
begin
  Result := nil;
  if FState.Input.RuntimeData <> nil then
    (FState.Input.RuntimeData as IHostData).Values.TryGetValue(Key, Result);
end;

procedure TRetroMulPlatformHost.SetData(const Key: string; const Value: IInterface);
begin
  if Value = nil then
  begin
    if FState.Input.RuntimeData <> nil then
      (FState.Input.RuntimeData as IHostData).Values.Remove(Key);
    Exit;
  end;
  if FState.Input.RuntimeData = nil then
    FState.Input.RuntimeData := THostData.Create;
  (FState.Input.RuntimeData as IHostData).Values.AddOrSetValue(Key, Value);
end;

procedure TRetroMulPlatformHost.ResetGame;
begin
  FView.ResetConsole(False);
end;

procedure TRetroMulPlatformHost.SetStatus(const Text: string);
begin
  FView.SetStatus(Text);
end;

procedure TRetroMulPlatformHost.ShowMessage(const Text: string; IsError: Boolean);
begin
  if IsError then
    ShowRetroMessage(FView, Text)
  else
    ShowRetroMessage(FView, Text, TRetroDialogKind.Information);
end;

function TRetroMulPlatformHost.GetPorts: TCoreInputPorts;
begin
  Result := FState.Input.Ports;
end;

procedure TRetroMulPlatformHost.SetPorts(const Ports: TCoreInputPorts);
begin
  FState.Input.Ports := Ports;
end;

function TRetroMulPlatformHost.GetHasInputSource: Boolean;
begin
  Result := FState.Input.Manager <> nil;
end;

function TRetroMulPlatformHost.GetBindings: TArray<TInputBinding>;
begin
  Result := nil;
  if GetHasInputSource then
    Result := FState.Input.Manager.Bindings;
end;

function TRetroMulPlatformHost.GetValues: TArray<TInputValue>;
begin
  Result := nil;
  if GetHasInputSource then
    Result := FState.Input.Manager.Values;
end;

function TRetroMulPlatformHost.IsActionPressed(Action: Integer): Boolean;
begin
  Result := GetHasInputSource and FState.Input.Manager.IsPressed(Action);
end;

function TRetroMulPlatformHost.ActionAmount(Action: Integer): Single;
begin
  Result := RM.Input.ActionAmount(FState.Input.Manager, GetBindings, GetValues, Action);
end;

function TRetroMulPlatformHost.DigitalAnalogAmount(Action: Integer; Pressed: Boolean): Single;
begin
  if FState.Input.Manager is TGamepadInputManager then
    Result := TGamepadInputManager(FState.Input.Manager).DigitalAnalogAmount(Action, Pressed)
  else
    Result := Ord(Pressed);
end;

procedure TRetroMulPlatformHost.ClearCachedInput;
begin
  FState.Input.GamepadInput := Default(TEmulatorInput);
end;

procedure TRetroMulPlatformHost.RequestInputUpdate(SubmitToCore: Boolean);
begin
  FView.UpdatePeripheralInput;
  var Core := GetCore;
  if SubmitToCore and (Core <> nil) then
    Core.SetGamepadInput(FView.CombinedGamepadInput);
end;

function TRetroMulPlatformHost.TryLocalToFrame(const Point: TPointF; out Pixel: TPoint): Boolean;
begin
  Result := TryGetImagePixel(FView.ImageCanvas, Point.X, Point.Y, Pixel.X, Pixel.Y);
end;

function TRetroMulPlatformHost.TryScreenToFrame(const Point: TPointF; out Pixel: TPoint): Boolean;
begin
  var local := FView.ImageCanvas.AbsoluteToLocal(FView.ScreenToClient(Point));
  Result := TryLocalToFrame(local, Pixel);
end;

function TRetroMulPlatformHost.TryPointerToFrame(out Pixel: TPoint): Boolean;
begin
  var Mouse: IFMXMouseService;
  if not TPlatformServices.Current.SupportsPlatformService(IFMXMouseService, Mouse) then
  begin
    Pixel := Point(-1, -1);
    Exit(False);
  end;
  Result := TryScreenToFrame(Mouse.GetMousePos, Pixel);
end;

function TRetroMulPlatformHost.GetPointerCaptured: Boolean;
begin
  var Canvas := FView.ImageCanvas;
  Result := (Canvas <> nil) and (Canvas.Root <> nil) and (Canvas.Root.Captured <> nil) and
    (Canvas.Root.Captured.GetObject = Canvas);
end;

procedure TRetroMulPlatformHost.SetPointerCaptured(Value: Boolean);
begin
  var Canvas := FView.ImageCanvas;
  if (Canvas = nil) or (Canvas.Root = nil) then
    Exit;
  if Value then
    Canvas.Root.SetCaptured(Canvas)
  else if GetPointerCaptured then
    Canvas.Root.SetCaptured(nil);
end;

procedure TRetroMulPlatformHost.SetPointerInputEnabled(Enabled, ShowFocus: Boolean);
begin
  var Canvas := FView.ImageCanvas;
  Canvas.HitTest := Enabled;
  Canvas.CanFocus := Enabled;
  Canvas.DisableFocusEffect := not ShowFocus;
  if Enabled then
  begin
    Canvas.CanParentFocus := True;
    Canvas.OnKeyDown := FView.FormKeyDown;
    Canvas.OnKeyUp := FView.FormKeyUp;
  end;
end;

procedure TRetroMulPlatformHost.FitFrame;
begin
  FView.ImageCanvas.Margins.Left := 0;
  FView.ImageCanvas.Margins.Right := 0;
  FView.ImageCanvas.WrapMode := TImageWrapMode.Fit;
end;

function TRetroMulPlatformHost.GetInputForm: TCommonCustomForm;
begin
  Result := FView;
end;

function TRetroMulPlatformHost.GetContent: TControl;
begin
  Result := FView.LayoutClient;
end;

function TRetroMulPlatformHost.GetFrameLayer: TImage;
begin
  Result := FView.ImageCanvas;
end;

function TRetroMulPlatformHost.GetGamepad: TScreenGamepad;
begin
  Result := FState.Input.Gamepad;
end;

function TRetroMulPlatformHost.GetUsableSize: TSizeF;
begin
  Result := TSizeF.Create(FView.ClientWidth - FView.Padding.Left - FView.Padding.Right,
    FView.ClientHeight - FView.Padding.Top - FView.Padding.Bottom - FView.LayoutHead.Height);
end;

function TRetroMulPlatformHost.GetBottomInset: Single;
begin
  Result := FState.Input.BottomInset;
end;

procedure TRetroMulPlatformHost.OpenDocument(const Request: TPlatformDocumentRequest; const Selected: TPlatformDocumentAction);
begin
  if FState.Session.OpeningRom or not Assigned(Selected) then
    Exit;
  var Core := GetCore;
  var IsAlive := FState.Session.CallbackAlive;
  var Host: IPlatformHost := Self;
  var Options := Request;
  var OnSelected := Selected;
  FState.Session.OpeningRom := True;
  FView.FormDeactivate(FView);
  FView.SyncActivity;
  try
    FState.Session.FileDialog.InitialDirectory := '';
    FState.Session.FileDialog.FileMustExist := False;
    FState.Session.FileDialog.Title := Options.Title;
    FState.Session.FileDialog.Filter := Options.Filter;
    FState.Session.FileDialog.SelectFiles(
      procedure(const Selection: TFMXSelectionResult)
      begin
        if not IsAlive() then
          Exit;
        var Importing := False;
        try
          try
            if (Host.Core <> Core) or (Selection.Status = TFMXSelectionStatus.Cancelled) then
              Exit;
            if Selection.Error <> '' then
              raise EReadError.Create(Selection.Error);
            if Selection.Status <> TFMXSelectionStatus.Selected then
              Exit;
            {$IFDEF ANDROID}
            FState.Mobile.PlatformDocumentSelected := OnSelected;
            FState.Mobile.PlatformDocumentFolder := Options.SaveFolder;
            FState.Mobile.PlatformDocumentExtension := Options.Extension;
            FState.Mobile.PlatformDocumentCore := Core;
            FState.Mobile.Transfer.Import(Selection.Locations[0], Options.AllowedExtensions, Options.Title);
            Importing := True;
            {$ELSE}
            OnSelected(Selection.Locations[0]);
            {$ENDIF}
              except
            on E: Exception do
              Host.ShowMessage(E.Message, True);
          end;
        finally
          if not Importing then
            FView.FinishFileSelection;
        end;
      end);
  except
    FView.FinishFileSelection;
    raise;
  end;
end;

procedure TRetroMulPlatformHost.SaveDocument(const Request: TPlatformDocumentRequest; const Write: TPlatformDocumentAction);
begin
  if FState.Session.OpeningRom or not Assigned(Write) then
    Exit;
  FView.FormDeactivate(FView);
  {$IFDEF ANDROID}
  var Storage := GetStorage;
  var Path := Storage.TemporaryFile(Request.Extension);
  var Exporting := False;
  try
    Write(Path);
    FState.Mobile.Transfer.Save(Path, Request.SuggestedName);
    Exporting := True;
    FState.Session.OpeningRom := True;
    FView.SyncActivity;
  finally
    if not Exporting then
    begin
      Storage.Delete(Path);
      FView.FormActivate(FView);
    end;
  end;
  {$ELSE}
  var Dialog := TSaveDialog.Create(FView);
  try
    Dialog.Title := Request.Title;
    Dialog.Filter := Request.Filter;
    Dialog.DefaultExt := Request.Extension.TrimLeft(['.']);
    Dialog.Options := [TOpenOption.ofPathMustExist, TOpenOption.ofOverwritePrompt];
    Dialog.FileName := Request.SuggestedName;
    var Core := GetCore;
    if Dialog.Execute and (GetCore = Core) then
      Write(Dialog.FileName);
  finally
    Dialog.Free;
    FView.FormActivate(FView);
  end;
  {$ENDIF}
end;

end.

