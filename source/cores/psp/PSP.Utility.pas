unit PSP.Utility;

// sceUtility: savedata, dialogs, on-screen keyboard, system parameters, modules.
// One dialog type is current at a time (the last one started); its status runs
// NONE -> INIT -> RUNNING -> FINISHED -> SHUTDOWN -> NONE on the master clock.
// Running dialogs draw over the game's framebuffer and use the controller's
// sampled buttons. A TPSPDialogView can replace the built-in software view;
// the headless test runner keeps the non-interactive path.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, PSP.Types,
  PSP.Memory, PSP.CPU, PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service,
  PSP.State.Action;

const
  PSPDialogNone = 0;
  PSPDialogInit = 1;
  PSPDialogRunning = 2;
  PSPDialogFinished = 3;
  PSPDialogShutdown = 4;

type
  TPSPDialogType = (dtNone, dtMsg, dtSavedata, dtOsk, dtNetconf, dtGameSharing, dtScreenshot, dtInstall,
    dtNpSignin, dtHtml);

  TPSPDialog = class
  public
    Kind: TPSPDialogType;
    Status: Cardinal;
    Params: Cardinal;
    Size: Cardinal;
    Updates: Integer;
    InitAt, RunningAt: Int64;
    // An Update arrived while initialising.
    Pumped: Boolean;
    Aborted: Boolean;
    // A result the dialog finishes with on its own (bad parameters).
    Error: Cardinal;
    // Savedata work has completed (interactive modes first wait for a choice).
    Done: Boolean;
    Selection, Stage, OskField: Integer;
    Choices: TArray<string>;
    Text: string;
  end;

  // Draws a running dialog and returns the buttons (PSP_CTRL_*) held for it.
  TPSPDialogView = class
  public
    function Update(Dialog: TPSPDialog; Memory: TPSPMemory): Cardinal; virtual; abstract;
  end;

  TPSPUtility = class(TPSPService)
  private
    FCurrent: TPSPDialogType;
    FDialogs: array[TPSPDialogType] of TPSPDialog;
    FHtmlStarted: Boolean;
    FHtmlMemory: Cardinal;
    FModules: TList<Cardinal>;
    FDelayWord: Cardinal;
    FView, FSoftwareView: TPSPDialogView;
    FLastButtons: Cardinal;
    // The dialog's own threads, as one guest thread that keeps the CPU until FWorkUntil.
    FWorkIndex: Integer;
    FWorkStub: Cardinal;
    FWorkThread: TPSPThread;
    FWorkUntil: Int64;
    function Interactive: Boolean;
    function ConfirmButton: Cardinal;
    function CancelButton: Cardinal;
    procedure Work(D: TPSPDialog; Ns: Int64);
    procedure hDialogThread;
    function Dialog(Kind: TPSPDialogType): TPSPDialog; inline;
    function Busy: Boolean;
    procedure Yield(Us: Cardinal);
    procedure At(Delay: Int64; D: TPSPDialog; Phase: Integer);
    procedure StateDialog(Action: TPSPStateAction; Value: Cardinal);
    procedure EnterRunning(D: TPSPDialog);
    procedure Finish(D: TPSPDialog);
    procedure InitStart(Kind: TPSPDialogType; const Sizes: array of Cardinal);
    procedure GetStatus(Kind: TPSPDialogType);
    procedure Update(Kind: TPSPDialogType);
    procedure ShutdownStart(Kind: TPSPDialogType);
    procedure Step(D: TPSPDialog);
    procedure StepMsg(D: TPSPDialog);
    procedure StepOsk(D: TPSPDialog);
    procedure StepOther(D: TPSPDialog);
    procedure CheckMsgParams(D: TPSPDialog);
    procedure TraceStart(D: TPSPDialog);
    function Pressed(D: TPSPDialog): Cardinal;
    // Savedata
    procedure StepSavedata(D: TPSPDialog);
    // Modules
    procedure ModuleLoad(Id: Cardinal; Valid: Boolean; ErrBase: Cardinal);
    procedure ModuleUnload(Id: Cardinal; Valid: Boolean; ErrBase: Cardinal);
    // HLE
    procedure hMsgInitStart;
    procedure hMsgGetStatus;
    procedure hMsgUpdate;
    procedure hMsgShutdownStart;
    procedure hMsgAbort;
    procedure hSavedataInitStart;
    procedure hSavedataGetStatus;
    procedure hSavedataUpdate;
    procedure hSavedataShutdownStart;
    procedure hOskInitStart;
    procedure hOskGetStatus;
    procedure hOskUpdate;
    procedure hOskShutdownStart;
    procedure hNetconfInitStart;
    procedure hNetconfGetStatus;
    procedure hNetconfUpdate;
    procedure hNetconfShutdownStart;
    procedure hSharingInitStart;
    procedure hSharingGetStatus;
    procedure hSharingUpdate;
    procedure hSharingShutdownStart;
    procedure hScreenshotInitStart;
    procedure hScreenshotGetStatus;
    procedure hScreenshotUpdate;
    procedure hScreenshotShutdownStart;
    procedure hScreenshotContStart;
    procedure hInstallInitStart;
    procedure hInstallGetStatus;
    procedure hNpSigninInitStart;
    procedure hNpSigninGetStatus;
    procedure hNpSigninUpdate;
    procedure hNpSigninShutdownStart;
    procedure hHtmlInitStart;
    procedure hHtmlGetStatus;
    procedure hHtmlUpdate;
    procedure hHtmlShutdownStart;
    procedure hGetSystemParamInt;
    procedure hGetSystemParamString;
    procedure hSetSystemParamInt;
    procedure hSetSystemParamString;
    procedure hCheckNetParam;
    procedure hGetNetParam;
    procedure hLoadModule;
    procedure hUnloadModule;
    procedure hLoadNetModule;
    procedure hUnloadNetModule;
    procedure hLoadAvModule;
    procedure hUnloadAvModule;
    procedure hLoadUsbModule;
    procedure hUnloadUsbModule;
  public
    constructor Create(System: TPSPSystem); override;
    destructor Destroy; override;
    procedure Reset; override;
    procedure Register; override;
    property View: TPSPDialogView read FView write FView;
  end;

const
  SCE_UTILITY_ERROR_INVALID_STATUS = Cardinal($80110001);
  SCE_UTILITY_ERROR_INVALID_PARAM_SIZE = Cardinal($80110004);
  SCE_UTILITY_ERROR_WRONG_TYPE = Cardinal($80110005);

implementation

uses
  System.Math, System.IOUtils, System.Hash, PSP.SysMem, PSP.IO, PSP.SFO,
  PSP.Settings, PSP.Font, PSP.Display, PSP.GE, PSP.GE.Types;

const
  // A message dialog leaves INIT this long after InitStart, or sooner when the
  // program pumps it with Update meanwhile.
  MsgInitNs = 650000000;
  MsgPumpedInitNs = 540000000;
  MsgFadeUpdates = 8;
  DialogShutdownNs = 25000000;
  DialogShutdownWorkNs = 8000000;
  SavedataInitNs = 33000000;
  SavedataShutdownNs = 500000;
  // The utility's own thread runs at this priority: a caller below it never sees SHUTDOWN.
  UtilityThreadPriority = 32;
  HeadlessAnswerNs: Int64 = 3000000000;
  UpdateYieldUs = 100;
  PSP_CTRL_CROSS = $4000;
  PSP_CTRL_CIRCLE = $2000;
  PSP_CTRL_UP = $10;
  PSP_CTRL_RIGHT = $20;
  PSP_CTRL_DOWN = $40;
  PSP_CTRL_LEFT = $80;
  PSP_CTRL_START = $8;
  PSP_CTRL_SQUARE = $8000;

{ Software utility UI. Pixels go into the same VRAM buffers as the game's GE
  lists; no host window, font or input polling is involved. }

type
  TSoftwareDialogView = class(TPSPDialogView)
  private
    FSystem: TPSPSystem;
    FFont: TPGFBuiltin;
    FBuffer: PByte;
    FStride, FFormat: Cardinal;
    procedure Pixel(X, Y: Integer; Color: Cardinal; Alpha: Integer = 15);
    procedure Rect(X, Y, W, H: Integer; Color: Cardinal);
    function Glyph(C: Char): TPGFGlyph;
    function TextWidth(const S: string): Integer;
    procedure Text(X, Y: Integer; const S: string; Color: Cardinal);
    procedure Wrapped(X, Y, W, Lines: Integer; const S: string);
    procedure Paint(D: TPSPDialog; Address, Stride, PixelFormat: Cardinal);
  public
    constructor Create(System: TPSPSystem);
    destructor Destroy; override;
    function Update(Dialog: TPSPDialog; Memory: TPSPMemory): Cardinal; override;
  end;

const
  OskKeys = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -._';
  // The dialogs' own words in the languages that have them (the dialog's
  // language, sceUtility's common parameters); English otherwise.
  PSP_SYSTEMPARAM_LANGUAGE_RUSSIAN = 8;
  DialogTexts: array[0..12] of record En, Ru: string; end = (
    (En: 'Message'; Ru: #$0421#$043E#$043E#$0431#$0449#$0435#$043D#$0438#$0435),
    (En: 'Enter'; Ru: #$0412#$0432#$043E#$0434),
    (En: 'Back'; Ru: #$041D#$0430#$0437#$0430#$0434),
    (En: 'Yes'; Ru: #$0414#$0430),
    (En: 'No'; Ru: #$041D#$0435#$0442),
    (En: 'An error has occurred.'; Ru: #$041F#$0440#$043E#$0438#$0437#$043E#$0448#$043B#$0430' '#$043E#$0448#$0438#$0431#$043A#$0430'.'),
    (En: 'Saved Data'; Ru: #$0421#$043E#$0445#$0440#$0430#$043D#$0435#$043D#$043D#$044B#$0435' '#$0434#$0430#$043D#$043D#$044B#$0435),
    (En: 'Up/Down Select'; Ru: #$0412#$0432#$0435#$0440#$0445'/'#$0432#$043D#$0438#$0437': '#$0432#$044B#$0431#$043E#$0440),
    (En: 'On-Screen Keyboard'; Ru: #$042D#$043A#$0440#$0430#$043D#$043D#$0430#$044F' '#$043A#$043B#$0430#$0432#$0438#$0430#$0442#$0443#$0440#$0430),
    (En: 'Type'; Ru: #$0412#$0432#$0435#$0441#$0442#$0438),
    (En: 'Square Delete'; Ru: #$041A#$0432#$0430#$0434#$0440#$0430#$0442': '#$0443#$0434#$0430#$043B#$0438#$0442#$044C),
    (En: 'Start Done'; Ru: 'Start: '#$0433#$043E#$0442#$043E#$0432#$043E),
    (En: 'Cancel'; Ru: #$041E#$0442#$043C#$0435#$043D#$0430));
  DialogInk = $FFEFEFEF;
  DialogPanel = $FF382A24;
  DialogAccent = $FFF1BA73;

constructor TSoftwareDialogView.Create(System: TPSPSystem);
begin
  inherited Create;
  FSystem := System;
end;

destructor TSoftwareDialogView.Destroy;
begin
  FFont.Free;
  inherited;
end;

procedure TSoftwareDialogView.Pixel(X, Y: Integer; Color: Cardinal; Alpha: Integer);
begin
  if (X < 0) or (Y < 0) or (X >= 480) or (Y >= 272) or (Alpha = 0) then
    Exit;
  var Bpp := 2;
  if FFormat = 3 then
    Bpp := 4;
  var P := FBuffer + (Cardinal(Y) * FStride + Cardinal(X)) * Cardinal(Bpp);
  var R := Color and $FF;
  var G := (Color shr 8) and $FF;
  var B := (Color shr 16) and $FF;
  if Alpha < 15 then
  begin
    var Old := PWord(P)^;
    var ORed, OGreen, OBlue: Cardinal;
    case FFormat of
      0:
        begin
          ORed := (Old and 31) * 255 div 31;
          OGreen := ((Old shr 5) and 63) * 255 div 63;
          OBlue := ((Old shr 11) and 31) * 255 div 31;
        end;
      1:
        begin
          ORed := (Old and 31) * 255 div 31;
          OGreen := ((Old shr 5) and 31) * 255 div 31;
          OBlue := ((Old shr 10) and 31) * 255 div 31;
        end;
      2:
        begin
          ORed := (Old and 15) * 17;
          OGreen := ((Old shr 4) and 15) * 17;
          OBlue := ((Old shr 8) and 15) * 17;
        end;
    else
      var C := PCardinal(P)^;
      ORed := C and $FF;
      OGreen := (C shr 8) and $FF;
      OBlue := (C shr 16) and $FF;
    end;
    R := (R * Cardinal(Alpha) + ORed * Cardinal(15 - Alpha) + 7) div 15;
    G := (G * Cardinal(Alpha) + OGreen * Cardinal(15 - Alpha) + 7) div 15;
    B := (B * Cardinal(Alpha) + OBlue * Cardinal(15 - Alpha) + 7) div 15;
  end;
  case FFormat of
    0:
      PWord(P)^ := (R shr 3) or ((G shr 2) shl 5) or ((B shr 3) shl 11);
    1:
      PWord(P)^ := (R shr 3) or ((G shr 3) shl 5) or ((B shr 3) shl 10) or $8000;
    2:
      PWord(P)^ := (R shr 4) or ((G shr 4) shl 4) or ((B shr 4) shl 8) or $F000;
    3:
      PCardinal(P)^ := R or (G shl 8) or (B shl 16) or $FF000000;
  end;
end;

procedure TSoftwareDialogView.Rect(X, Y, W, H: Integer; Color: Cardinal);
begin
  for var J := Max(0, Y) to Min(271, Y + H - 1) do
    for var I := Max(0, X) to Min(479, X + W - 1) do
      Pixel(I, J, Color);
end;

function TSoftwareDialogView.Glyph(C: Char): TPGFGlyph;
begin
  var I := FFont.Lookup(Ord(C));
  if I < 0 then
    I := FFont.Lookup(Ord('?'));
  Result := FFont.Glyph(I);
end;

function TSoftwareDialogView.TextWidth(const S: string): Integer;
begin
  Result := 0;
  for var C in S do
    Inc(Result, (Glyph(C).Advance.X + 32) div 64);
end;

procedure TSoftwareDialogView.Text(X, Y: Integer; const S: string; Color: Cardinal);
begin
  for var C in S do
  begin
    var G := Glyph(C);
    for var J := 0 to G.H - 1 do
      for var I := 0 to G.W - 1 do
        Pixel(X + G.Left + I, Y + 12 - G.Top + J, Color, G.Pixel(I, J));
    Inc(X, (G.Advance.X + 32) div 64);
  end;
end;

// S broken into rows of at most W pixels (at spaces where it can) over the
// height of Lines rows of 17 pixels: rows closer together (down to 13
// pixels) when there are more.
procedure TSoftwareDialogView.Wrapped(X, Y, W, Lines: Integer; const S: string);
var
  Rows: TList<string>;
begin
  Rows := TList<string>.Create;
  try
    var Start := 1;
    while (Start <= Length(S)) and (Rows.Count < Lines * 17 div 13) do
    begin
      var N := Start;
      var Width := 0;
      var LastSpace := 0;
      while (N <= Length(S)) and (S[N] <> #10) do
      begin
        var Advance := (Glyph(S[N]).Advance.X + 32) div 64;
        if Width + Advance > W then
          Break;
        Inc(Width, Advance);
        if S[N] = ' ' then
          LastSpace := N;
        Inc(N);
      end;
      if (N <= Length(S)) and (S[N] <> #10) and (LastSpace > Start) then
        N := LastSpace;
      Rows.Add(Copy(S, Start, N - Start).Replace(#13, ''));
      Start := N;
      if (Start <= Length(S)) and CharInSet(S[Start], [' ', #10]) then
        Inc(Start);
    end;
    var Spacing := 17;
    if Rows.Count > Lines then
      Spacing := Max(13, Lines * 17 div Rows.Count);
    for var Row := 0 to Min(Rows.Count, Lines * 17 div Spacing) - 1 do
      Text(X, Y + Row * Spacing, Rows[Row], DialogInk);
  finally
    Rows.Free;
  end;
end;

// The dialog's word for En in Language.
function DialogText(const En: string; Language: Cardinal): string;
begin
  Result := En;
  if Language <> PSP_SYSTEMPARAM_LANGUAGE_RUSSIAN then
    Exit;
  for var I := 0 to High(DialogTexts) do
    if DialogTexts[I].En = En then
      Exit(DialogTexts[I].Ru);
end;

procedure TSoftwareDialogView.Paint(D: TPSPDialog; Address, Stride, PixelFormat: Cardinal);
begin
  if (Address = 0) or (Stride < 480) or (Stride > 2048) or (PixelFormat > 3) then
    Exit;
  var Bpp: Cardinal := 2;
  if PixelFormat = 3 then
    Bpp := 4;
  FBuffer := FSystem.Memory.Ptr(Address, Stride * 272 * Bpp);
  if FBuffer = nil then
    Exit;
  if FFont = nil then
    FFont := TPGFBuiltin.Create(8, False, False);
  FStride := Stride;
  FFormat := PixelFormat;
  Rect(24, 28, 432, 216, DialogPanel);
  Rect(24, 28, 432, 2, DialogAccent);
  Rect(24, 242, 432, 2, DialogAccent);
  var M := FSystem.Memory;
  var P := D.Params;
  // pspUtilityDialogCommon's language.
  var Lang := M.Read32(P + 4);
  var Title := DialogText('Message', Lang);
  var Body := D.Text;
  var Confirm := 'X';
  var Cancel := 'O';
  if PSPSettings.ButtonSwap = 0 then
  begin
    Confirm := 'O';
    Cancel := 'X';
  end;
  var Footer := Confirm + ' ' + DialogText('Enter', Lang) + '    ' + Cancel + ' ' + DialogText('Back', Lang);
  case D.Kind of
    dtMsg:
      begin
        if M.Read32(P + $34) = 0 then
          Body := DialogText('An error has occurred.', Lang) + #10 + Format('(%s)', [IntToHex(M.Read32(P + $38), 8)])
        else
          Body := UTF8ToString(M.ReadAnsi(P + $3C, 512));
        var Options: Cardinal := 0;
        if D.Size > $23C then
          Options := M.Read32(P + $23C);
        if (Options and $10) <> 0 then
        begin
          var Yes := DialogText('Yes', Lang);
          var No := DialogText('No', Lang);
          if D.Selection = 0 then
            Text(170, 196, '[ ' + Yes + ' ]       ' + No, DialogAccent)
          else
            Text(170, 196, '  ' + Yes + '       [ ' + No + ' ]', DialogAccent);
        end;
        if (Options and $80) <> 0 then
          Footer := Confirm + ' ' + DialogText('Enter', Lang);
      end;
    dtSavedata:
      begin
        Title := DialogText('Saved Data', Lang);
        if Length(D.Choices) > 1 then
        begin
          var First := Max(0, D.Selection - 2);
          for var I := First to Min(High(D.Choices), First + 3) do
          begin
            var Prefix := '   ';
            var Ink := DialogInk;
            if I = D.Selection then
            begin
              Prefix := '> ';
              Ink := DialogAccent;
            end;
            Text(48, 116 + (I - First) * 19, Prefix + Copy(D.Choices[I], 1, 42), Ink);
          end;
          Footer := DialogText('Up/Down Select', Lang) + '    ' + Footer;
        end;
      end;
    dtOsk:
      begin
        Title := DialogText('On-Screen Keyboard', Lang);
        Body := D.Text;
        Text(44, 76, Copy(D.Text, Max(1, Length(D.Text) - 47), 48), DialogAccent);
        Body := '';
        for var I := 0 to Length(OskKeys) - 1 do
        begin
          var X := 48 + (I mod 10) * 38;
          var Y := 106 + (I div 10) * 22;
          if I = D.Selection then
            Rect(X - 6, Y - 2, 28, 20, $FF72503D);
          var C := OskKeys[I + 1];
          if C = ' ' then
            C := '_';
          Text(X, Y, C, DialogInk);
        end;
        Footer := Confirm + ' ' + DialogText('Type', Lang) + '  ' + DialogText('Square Delete', Lang) + '  ' +
          DialogText('Start Done', Lang) + '  ' + Cancel + ' ' + DialogText('Cancel', Lang);
      end;
  end;
  Text(42, 43, Title, DialogAccent);
  Rect(42, 65, 396, 1, $FF79685A);
  var Lines := 7;
  if D.Kind = dtSavedata then
    Lines := 2;
  Wrapped(44, 79, 390, Lines, Body);
  Text(42, 220, Footer, DialogInk);
end;

function TSoftwareDialogView.Update(Dialog: TPSPDialog; Memory: TPSPMemory): Cardinal;
begin
  var Display := FSystem.Display;
  Paint(Dialog, Display.CurrentAddress, Display.Width, Display.Format);
  // The game may have finished drawing its next buffer but not flipped it yet.
  var GE := TPSPGE(FSystem.Find(TPSPGE));
  if GE <> nil then
  begin
    var Addr := PSPVRAMBase + (GE.Engine.Regs.Cmd[GE_FRAMEBUFPTR] and $1FFFF0);
    if (Addr and $1FFFFF) <> (Display.CurrentAddress and $1FFFFF) then
      Paint(Dialog, Addr, GE.Engine.Regs.Cmd[GE_FRAMEBUFWIDTH] and $7FC,
        GE.Engine.Regs.Cmd[GE_FRAMEBUFPIXFORMAT] and 3);
  end;
  Result := Display.SampledButtons;
end;

{ PSP.Utility: message dialog, OSK, the dialogs that only fail offline, the
  HTML viewer, system parameters and utility modules. }

const
  MsgResult = $30;
  MsgMode = $34;
  MsgErrorNum = $38;
  MsgOptions = $23C;
  MsgButton = $240;
  MSG_ERROR_BAD_OPTION = Cardinal($80110501);
  MSG_ERROR_BAD_ERRORCODE = Cardinal($80110502);
  MSG_OPTION_DEFAULT_NO = $100;
  MSG_BUTTON_YES = 1;
  MSG_BUTTON_NO = 2;
  MSG_BUTTON_BACK = 3;
  DialogResult = $1C;
  OSK_RESULT_CHANGED = 2;
  SYSTEMPARAM_FAIL = Cardinal($80110103);
  SYSTEMPARAM_TOO_SHORT = Cardinal($80110102);
  NETPARAM_BAD_NETCONF = Cardinal($80110601);
  HtmlMemorySize = $380000;
  ModuleLoadUs = 1000;

procedure TPSPUtility.CheckMsgParams(D: TPSPDialog);
begin
  var P := D.Params;
  var BadOptions := (D.Size > MsgOptions) and ((FMemory.Read32(P + MsgOptions) and not $1FF) <> 0);
  if FMemory.Read32(P + MsgMode) = 0 then
  begin
    // Error dialogs only look at the options from the third version on.
    if FMemory.Read32(P + MsgErrorNum) = 0 then
      D.Error := MSG_ERROR_BAD_ERRORCODE
    else if BadOptions and (D.Size >= $2C4) then
      D.Error := MSG_ERROR_BAD_OPTION;
  end
  else if BadOptions then
    D.Error := MSG_ERROR_BAD_OPTION;
end;

procedure TPSPUtility.StepMsg(D: TPSPDialog);
begin
  var P := D.Params;
  // A failing dialog shows for its fade-in, then quits with the error.
  if D.Error <> 0 then
  begin
    if D.Updates > MsgFadeUpdates then
    begin
      FMemory.Write32(P + MsgResult, D.Error);
      Finish(D);
    end;
    Exit;
  end;
  // The first frame drawn clears the result.
  if D.Updates = 1 then
    FMemory.Write32(P + MsgResult, 0);
  if D.Aborted then
  begin
    if D.Updates >= MsgFadeUpdates then
      Finish(D);
    Exit;
  end;
  var B := Pressed(D);
  var Options: Cardinal := 0;
  if D.Size > MsgOptions then
    Options := FMemory.Read32(P + MsgOptions);
  var Answer := 0;
  if (Options and $10) <> 0 then
  begin
    if (B and PSP_CTRL_LEFT) <> 0 then
      D.Selection := 0;
    if (B and PSP_CTRL_RIGHT) <> 0 then
      D.Selection := 1;
  end;
  if (B and ConfirmButton) <> 0 then
    Answer := MSG_BUTTON_YES + D.Selection
  else if ((B and CancelButton) <> 0) and ((Options and $80) = 0) then
    Answer := MSG_BUTTON_BACK
  else if not Interactive and (FKernel.Scheduler.Now - D.RunningAt >= HeadlessAnswerNs) then
    Answer := MSG_BUTTON_YES + D.Selection;
  if (Answer <> 0) and (D.Updates >= MsgFadeUpdates) then
  begin
    if D.Size > MsgButton then
      FMemory.Write32(P + MsgButton, Cardinal(Answer));
    Finish(D);
  end;
end;

procedure TPSPUtility.StepOsk(D: TPSPDialog);
begin
  var P := D.Params;
  var Count := Integer(FMemory.Read32(P + $30));
  var Data := FMemory.Read32(P + $34);
  if Interactive and (Count > 0) and (Count <= 16) and (Data <> 0) then
  begin
    var F := Data + Cardinal(D.OskField) * 52;
    var InText := FMemory.Read32(F + 32);
    var Limit := Min(Integer(FMemory.Read32(F + 36)) - 1, 512);
    var InputLimit := Integer(FMemory.Read32(F + 48));
    if InputLimit > 0 then
      Limit := Min(Limit, InputLimit);
    if D.Stage = 0 then
    begin
      D.Text := '';
      if InText <> 0 then
        for var I := 0 to Max(0, Limit) - 1 do
        begin
          var C := FMemory.Read16(InText + Cardinal(I * 2));
          if C = 0 then
            Break;
          D.Text := D.Text + Char(C);
        end;
      D.Stage := 1;
    end;
    var B := Pressed(D);
    if (B and PSP_CTRL_LEFT) <> 0 then
      D.Selection := (D.Selection + 9) mod 10 + (D.Selection div 10) * 10;
    if (B and PSP_CTRL_RIGHT) <> 0 then
      D.Selection := (D.Selection + 1) mod 10 + (D.Selection div 10) * 10;
    if (B and PSP_CTRL_UP) <> 0 then
      D.Selection := (D.Selection + 30) mod 40;
    if (B and PSP_CTRL_DOWN) <> 0 then
      D.Selection := (D.Selection + 10) mod 40;
    if ((B and ConfirmButton) <> 0) and (Length(D.Text) < Limit) then
      D.Text := D.Text + OskKeys[D.Selection + 1];
    if ((B and PSP_CTRL_SQUARE) <> 0) and (D.Text <> '') then
      Delete(D.Text, Length(D.Text), 1);
    var Cancelled := (B and CancelButton) <> 0;
    if not Cancelled and ((B and PSP_CTRL_START) = 0) then
      Exit;
    var OutText := FMemory.Read32(F + 40);
    var ResultCode := OSK_RESULT_CHANGED;
    if Cancelled then
      ResultCode := 1
    else if (OutText <> 0) and (Limit >= 0) then
    begin
      for var I := 1 to Length(D.Text) do
        FMemory.Write16(OutText + Cardinal((I - 1) * 2), Ord(D.Text[I]));
      FMemory.Write16(OutText + Cardinal(Length(D.Text) * 2), 0);
    end;
    FMemory.Write32(F + 44, Cardinal(ResultCode));
    Inc(D.OskField);
    D.Stage := 0;
    if not Cancelled and (D.OskField < Count) then
      Exit;
    FMemory.Write32(P + DialogResult, 0);
    Finish(D);
    Exit;
  end;
  // A headless call confirms each field with its initial text.
  for var I := 0 to Count - 1 do
  begin
    var F := Data + Cardinal(I) * 52;
    var InText := FMemory.Read32(F + 32);
    var OutLength := Integer(FMemory.Read32(F + 36));
    var OutText := FMemory.Read32(F + 40);
    if OutText <> 0 then
    begin
      var N := 0;
      if InText <> 0 then
        while (N < OutLength - 1) and (FMemory.Read16(InText + Cardinal(N) * 2) <> 0) do
        begin
          FMemory.Write16(OutText + Cardinal(N) * 2, FMemory.Read16(InText + Cardinal(N) * 2));
          Inc(N);
        end;
      if OutLength > 0 then
        FMemory.Write16(OutText + Cardinal(N) * 2, 0);
    end;
    FMemory.Write32(F + 44, OSK_RESULT_CHANGED);
  end;
  FMemory.Write32(P + DialogResult, 0);
  Finish(D);
end;

procedure TPSPUtility.StepOther(D: TPSPDialog);
begin
  // Network dialogs find no access point; the others have nothing to show.
  // Each closes as if the player backed out.
  FMemory.Write32(D.Params + DialogResult, 1);
  Finish(D);
end;

{ Message dialog }

procedure TPSPUtility.hMsgInitStart;
begin
  InitStart(dtMsg, [$23C, $244, $2C4]);
end;

procedure TPSPUtility.hMsgGetStatus;
begin
  GetStatus(dtMsg);
end;

procedure TPSPUtility.hMsgUpdate;
begin
  Update(dtMsg);
end;

procedure TPSPUtility.hMsgShutdownStart;
begin
  ShutdownStart(dtMsg);
end;

procedure TPSPUtility.hMsgAbort;
begin
  if FCurrent <> dtMsg then
  begin
    FHLE.Result(SCE_UTILITY_ERROR_WRONG_TYPE);
    Exit;
  end;
  var D := FDialogs[dtMsg];
  if D.Status <> PSPDialogRunning then
  begin
    FHLE.Result(SCE_UTILITY_ERROR_INVALID_STATUS);
    Exit;
  end;
  D.Aborted := True;
  FHLE.Result(0);
end;

{ Savedata }

procedure TPSPUtility.hSavedataInitStart;
begin
  InitStart(dtSavedata, [$5C8, $5DC, $600]);
end;

procedure TPSPUtility.hSavedataGetStatus;
begin
  GetStatus(dtSavedata);
end;

procedure TPSPUtility.hSavedataUpdate;
begin
  Update(dtSavedata);
end;

procedure TPSPUtility.hSavedataShutdownStart;
begin
  ShutdownStart(dtSavedata);
end;

{ OSK }

procedure TPSPUtility.hOskInitStart;
begin
  InitStart(dtOsk, [$40, $44]);
end;

procedure TPSPUtility.hOskGetStatus;
begin
  GetStatus(dtOsk);
end;

procedure TPSPUtility.hOskUpdate;
begin
  Update(dtOsk);
end;

procedure TPSPUtility.hOskShutdownStart;
begin
  ShutdownStart(dtOsk);
end;

{ Netconf }

procedure TPSPUtility.hNetconfInitStart;
begin
  InitStart(dtNetconf, [$38, $40, $44]);
end;

procedure TPSPUtility.hNetconfGetStatus;
begin
  GetStatus(dtNetconf);
end;

procedure TPSPUtility.hNetconfUpdate;
begin
  Update(dtNetconf);
end;

procedure TPSPUtility.hNetconfShutdownStart;
begin
  ShutdownStart(dtNetconf);
end;

{ Game sharing }

procedure TPSPUtility.hSharingInitStart;
begin
  InitStart(dtGameSharing, [$50, $54, $64]);
end;

procedure TPSPUtility.hSharingGetStatus;
begin
  GetStatus(dtGameSharing);
end;

procedure TPSPUtility.hSharingUpdate;
begin
  Update(dtGameSharing);
end;

procedure TPSPUtility.hSharingShutdownStart;
begin
  ShutdownStart(dtGameSharing);
end;

{ Screenshot }

procedure TPSPUtility.hScreenshotInitStart;
begin
  InitStart(dtScreenshot, [$1B4, $3A0, $3A4]);
end;

procedure TPSPUtility.hScreenshotGetStatus;
begin
  GetStatus(dtScreenshot);
end;

procedure TPSPUtility.hScreenshotUpdate;
begin
  Update(dtScreenshot);
end;

procedure TPSPUtility.hScreenshotShutdownStart;
begin
  ShutdownStart(dtScreenshot);
end;

procedure TPSPUtility.hScreenshotContStart;
begin
  if FCurrent <> dtScreenshot then
  begin
    FHLE.Result(SCE_UTILITY_ERROR_WRONG_TYPE);
    Exit;
  end;
  FHLE.Result(SCE_UTILITY_ERROR_INVALID_STATUS);
end;

{ Gamedata install }

procedure TPSPUtility.hInstallInitStart;
begin
  InitStart(dtInstall, [$590, $598]);
end;

procedure TPSPUtility.hInstallGetStatus;
begin
  GetStatus(dtInstall);
end;

{ NP sign-in }

procedure TPSPUtility.hNpSigninInitStart;
begin
  InitStart(dtNpSignin, [$40]);
end;

procedure TPSPUtility.hNpSigninGetStatus;
begin
  GetStatus(dtNpSignin);
end;

procedure TPSPUtility.hNpSigninUpdate;
begin
  Update(dtNpSignin);
end;

procedure TPSPUtility.hNpSigninShutdownStart;
begin
  ShutdownStart(dtNpSignin);
end;

{ HTML viewer: its own state, not blocked by the other dialogs. It needs a
  3.5 MB block of user memory for the browser. }

procedure TPSPUtility.hHtmlInitStart;
begin
  var D := FDialogs[dtHtml];
  var P := FHLE.Arg(0);
  if FHtmlStarted and (D.Status <> PSPDialogNone) then
  begin
    FHLE.Result(SCE_UTILITY_ERROR_INVALID_STATUS);
    Exit;
  end;
  var Size: Cardinal := 0;
  if P <> 0 then
    Size := FMemory.Read32(P);
  if not ((Size = $70) or (Size = $78) or (Size = $80) or (Size = $98) or (Size = $A4) or (Size = $A8)) then
  begin
    FHLE.Result(SCE_UTILITY_ERROR_INVALID_PARAM_SIZE);
    Exit;
  end;
  var Block := FKernel.UserPartition.Alloc(HtmlMemorySize, akHigh, 0, 256, 'htmlviewer');
  if Block = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_MEMBLOCK_ALLOC_FAILED);
    Exit;
  end;
  FHtmlMemory := Block;
  FHtmlStarted := True;
  FKernel.CancelTimersOf(D);
  D.Status := PSPDialogInit;
  D.Params := P;
  D.Size := Size;
  D.Updates := 0;
  FHLE.Result(0);
  At(SavedataInitNs, D, 3);
end;

procedure TPSPUtility.hHtmlGetStatus;
begin
  if not FHtmlStarted then
    FHLE.Result(SCE_UTILITY_ERROR_WRONG_TYPE)
  else
    FHLE.Result(FDialogs[dtHtml].Status);
end;

procedure TPSPUtility.hHtmlUpdate;
begin
  var D := FDialogs[dtHtml];
  if not FHtmlStarted then
  begin
    FHLE.Result(SCE_UTILITY_ERROR_WRONG_TYPE);
    Exit;
  end;
  if D.Status <> PSPDialogRunning then
  begin
    FHLE.Result(SCE_UTILITY_ERROR_INVALID_STATUS);
    Exit;
  end;
  FHLE.Result(0);
  // No network: the browser can only be closed.
  FMemory.Write32(D.Params + DialogResult, 0);
  Finish(D);
  Yield(UpdateYieldUs);
end;

procedure TPSPUtility.hHtmlShutdownStart;
begin
  var D := FDialogs[dtHtml];
  if not FHtmlStarted then
  begin
    FHLE.Result(SCE_UTILITY_ERROR_WRONG_TYPE);
    Exit;
  end;
  if D.Status <> PSPDialogFinished then
  begin
    FHLE.Result(SCE_UTILITY_ERROR_INVALID_STATUS);
    Exit;
  end;
  FHLE.Result(0);
  D.Status := PSPDialogShutdown;
  At(DialogShutdownNs, D, 4);
end;

{ System parameters }

procedure TPSPUtility.hGetSystemParamInt;
begin
  var V: Integer;
  case FHLE.ArgInt(0) of
    2:
      V := PSPSettings.AdhocChannel;
    3:
      V := PSPSettings.WlanPowerSave;
    4:
      V := PSPSettings.DateFormat;
    5:
      V := PSPSettings.TimeFormat;
    6:
      V := PSPSettings.Timezone;
    7:
      V := PSPSettings.DaylightSaving;
    8:
      V := PSPSettings.Language;
    9:
      V := PSPSettings.ButtonSwap;
    10:
      V := PSPSettings.ParentalLevel;
  else
    begin
      FHLE.Result(SYSTEMPARAM_FAIL);
      Exit;
    end;
  end;
  FMemory.Write32(FHLE.Arg(1), Cardinal(V));
  FHLE.Result(0);
end;

procedure TPSPUtility.hGetSystemParamString;
begin
  if FHLE.ArgInt(0) <> 1 then
  begin
    FHLE.Result(SYSTEMPARAM_FAIL);
    Exit;
  end;
  var S := UTF8Encode(PSPSettings.Nickname);
  var Len := FHLE.ArgInt(2);
  if Len <= Length(S) then
  begin
    FHLE.Result(SYSTEMPARAM_TOO_SHORT);
    Exit;
  end;
  FMemory.WriteString(FHLE.Arg(1), S, Len);
  FHLE.Result(0);
end;

procedure TPSPUtility.hSetSystemParamInt;
begin
  var V := FHLE.ArgInt(1);
  case FHLE.ArgInt(0) of
    2:
      PSPSettings.AdhocChannel := V;
    3:
      PSPSettings.WlanPowerSave := V;
    4:
      PSPSettings.DateFormat := V;
    5:
      PSPSettings.TimeFormat := V;
    6:
      PSPSettings.Timezone := V;
    7:
      PSPSettings.DaylightSaving := V;
    8:
      PSPSettings.Language := V;
    9:
      PSPSettings.ButtonSwap := V;
    10:
      PSPSettings.ParentalLevel := V;
  else
    begin
      FHLE.Result(SYSTEMPARAM_FAIL);
      Exit;
    end;
  end;
  FHLE.Result(0);
end;

procedure TPSPUtility.hSetSystemParamString;
begin
  if FHLE.ArgInt(0) <> 1 then
  begin
    FHLE.Result(SYSTEMPARAM_FAIL);
    Exit;
  end;
  PSPSettings.Nickname := UTF8ToString(FMemory.ReadAnsi(FHLE.Arg(1), 128));
  FHLE.Result(0);
end;

procedure TPSPUtility.hCheckNetParam;
begin
  // No network configurations are stored.
  FHLE.Result(NETPARAM_BAD_NETCONF);
end;

procedure TPSPUtility.hGetNetParam;
begin
  FHLE.Result(NETPARAM_BAD_NETCONF);
end;

{ Modules: the libraries are always present; loading only tracks the state
  and takes the time a load from flash takes. }

procedure TPSPUtility.ModuleLoad(Id: Cardinal; Valid: Boolean; ErrBase: Cardinal);
begin
  if not Valid then
  begin
    FHLE.Result(ErrBase + 1);
    Exit;
  end;
  if FModules.Contains(Id) then
  begin
    FHLE.Result(ErrBase + 2);
    Exit;
  end;
  FModules.Add(Id);
  FHLE.Result(0);
  Yield(ModuleLoadUs);
end;

procedure TPSPUtility.ModuleUnload(Id: Cardinal; Valid: Boolean; ErrBase: Cardinal);
begin
  if not Valid then
  begin
    FHLE.Result(ErrBase + 1);
    Exit;
  end;
  if not FModules.Contains(Id) then
  begin
    FHLE.Result(ErrBase + 3);
    Exit;
  end;
  FModules.Remove(Id);
  FHLE.Result(0);
  Yield(ModuleLoadUs);
end;

function ValidUtilityModule(Id: Cardinal): Boolean;
begin
  case Id shr 8 of
    1:
      Result := (Id and $FF) <= 6;
    2:
      Result := (Id and $FF) <= 3;
    3:
      Result := (Id and $FF) <= 8;
    4:
      Result := (Id and $FF) <= 2;
    5:
      Result := (Id and $FF) <= 1;
    6:
      Result := (Id and $FF) = 0;
  else
    Result := False;
  end;
end;

procedure TPSPUtility.hLoadModule;
begin
  ModuleLoad(FHLE.Arg(0), ValidUtilityModule(FHLE.Arg(0)), $80111100);
end;

procedure TPSPUtility.hUnloadModule;
begin
  ModuleUnload(FHLE.Arg(0), ValidUtilityModule(FHLE.Arg(0)), $80111100);
end;

procedure TPSPUtility.hLoadNetModule;
begin
  var N := FHLE.Arg(0);
  ModuleLoad($100 + N - 1, (N >= 1) and (N <= 7), $80110800);
end;

procedure TPSPUtility.hUnloadNetModule;
begin
  var N := FHLE.Arg(0);
  ModuleUnload($100 + N - 1, (N >= 1) and (N <= 7), $80110800);
end;

procedure TPSPUtility.hLoadAvModule;
begin
  var N := FHLE.Arg(0);
  ModuleLoad($300 + N, N <= 7, $80110F00);
end;

procedure TPSPUtility.hUnloadAvModule;
begin
  var N := FHLE.Arg(0);
  ModuleUnload($300 + N, N <= 7, $80110F00);
end;

procedure TPSPUtility.hLoadUsbModule;
begin
  var N := FHLE.Arg(0);
  ModuleLoad($10200 + N, (N >= 1) and (N <= 5), $80110B00);
end;

procedure TPSPUtility.hUnloadUsbModule;
begin
  var N := FHLE.Arg(0);
  ModuleUnload($10200 + N, (N >= 1) and (N <= 5), $80110B00);
end;

{ PSP.Utility: savedata. A save is the folder ms0:/PSP/SAVEDATA/<game><save>
  with a PARAM.SFO; files written by the secure modes with a key are listed in
  its SAVEDATA_FILE_LIST, and SAVEDATA_PARAMS[0] records the protection mode.
  The data itself is stored as given (the mode is kept, not applied). In the
  headless runner list modes take the first listed save. }

const
  SdMode = $30;
  SdBind = $34;
  SdGameName = $3C;
  SdSaveName = $4C;
  SdSaveNameList = $60;
  SdFileName = $64;
  SdDataBuf = $74;
  SdDataBufSize = $78;
  SdDataSize = $7C;
  SdTitle = $80;
  SdSavedataTitle = $100;
  SdDetail = $180;
  SdParental = $580;
  SdIcon0 = $584;
  SdMsFree = $5D0;
  SdMsData = $5D4;
  SdUtilityData = $5D8;
  SdKey = $5DC;
  SdSecureVersion = $5EC;
  SdIdList = $5F4;
  SdFileList = $5F8;
  SdSizeInfo = $5FC;

  SD_LOAD_NO_MS = Cardinal($80110301);
  SD_LOAD_BROKEN = Cardinal($80110306);
  SD_LOAD_NO_DATA = Cardinal($80110307);
  SD_LOAD_PARAM = Cardinal($80110308);
  SD_LOAD_NO_FILE = Cardinal($80110309);
  SD_RW_NO_MS = Cardinal($80110321);
  SD_RW_BROKEN = Cardinal($80110326);
  SD_RW_NO_DATA = Cardinal($80110327);
  SD_RW_PARAM = Cardinal($80110328);
  SD_RW_NO_FILE = Cardinal($80110329);
  SD_DELETE_NO_MS = Cardinal($80110341);
  SD_DELETE_NO_DATA = Cardinal($80110347);
  SD_SAVE_NO_MS = Cardinal($80110381);
  SD_SAVE_PARAM = Cardinal($80110388);
  SD_SIZES_NO_MS = Cardinal($801103C1);

  SdClusterSize = $8000;
  // What the utility reports for an empty 16 GB stick.
  SdFreeClusters = $7FFFF;
  SdFreeKB = $FFFFFB;

  SfoFileListSize = $C60;
  SfoParamsSize = $80;
  SdSystemFiles: array[0..4] of string = ('PARAM.SFO', 'ICON0.PNG', 'ICON1.PMF', 'PIC1.PNG', 'SND0.AT3');

type
  ESaveName = class(Exception);

  TSaveFile = record
    Name: string;
    Size: Int64;
    Time: TDateTime;
  end;

  TSavedataRunner = class
  public
    M: TPSPMemory;
    Kernel: TPSPKernel;
    P, Size: Cardinal;
    Mode: Integer;
    GameName, SaveName, FileName: string;
    Key: TBytes;
    HasKey, HasVersion, Selected: Boolean;
    SecureVersion: Integer;
    Root: string;
    IO: TPSPIO;
    function Run: Cardinal;
    function RunMode: Cardinal;
    function Dir(const Name: string): string;
    function ModeByte(V: Integer): Byte;
    function ParamOk: Boolean;
    function Listed: TArray<string>;
    function FirstExisting(out Name: string): Boolean;
    function NowTime: TDateTime;
    procedure Stamp(const Path: string);
    procedure ReadGuest(Address, Size: Cardinal; out Data: TBytes);
    procedure LoadIcons(const D: string);
    procedure SaveIcons(const D: string);
    procedure FillSfoParam(Sfo: TPSPSFO);
    function WriteSave(const Name: string; Secure, NeedExisting: Boolean; out Res: Cardinal): Boolean;
    function DeleteSave(const Name: string): Boolean;
    function Load: Cardinal;
    function Read(Secure: Boolean): Cardinal;
    function Save: Cardinal;
    function Make(Secure: Boolean): Cardinal;
    function Write(Secure: Boolean): Cardinal;
    function Erase: Cardinal;
    function Sizes: Cardinal;
    function List: Cardinal;
    function Files: Cardinal;
    function GetSize: Cardinal;
  end;

function SdKeyIsSet(const Key: TBytes): Boolean;
begin
  for var B in Key do
    if B <> 0 then
      Exit(True);
  Result := False;
end;

function SdClusters(Size: Int64): Int64;
begin
  Result := (Size + SdClusterSize - 1) div SdClusterSize;
end;

function SdSizeString(KB: Int64): RawByteString;
begin
  if KB < 1024 then
    Result := RawByteString(Format('%d KB', [KB]))
  else if KB < 1024 * 1024 then
    Result := RawByteString(Format('%d MB', [KB div 1024]))
  else
    Result := RawByteString(Format('%d GB', [KB div (1024 * 1024)]));
end;

function SdFiles(const Dir: string): TArray<TSaveFile>;
begin
  Result := nil;
  if not TDirectory.Exists(Dir) then
    Exit;
  var Names := TDirectory.GetFiles(Dir);
  TArray.Sort<string>(Names);
  for var N in Names do
  begin
    var F: TSaveFile;
    F.Name := ExtractFileName(N).ToUpper;
    F.Size := TFile.GetSize(N);
    F.Time := TFile.GetLastWriteTime(N);
    Result := Result + [F];
  end;
end;

function SdUsedClusters(const Dir: string): Int64;
begin
  // The folder takes a cluster of its own.
  Result := 1;
  for var F in SdFiles(Dir) do
    Inc(Result, SdClusters(F.Size));
end;

function SdMatch(const Pattern, Name: string): Boolean;
begin
  // '?' is any one character, '*' any run.
  var P := 1;
  var N := 1;
  var StarP := 0;
  var StarN := 0;
  while N <= Length(Name) do
  begin
    if (P <= Length(Pattern)) and ((Pattern[P] = '?') or (UpCase(Pattern[P]) = UpCase(Name[N]))) then
    begin
      Inc(P);
      Inc(N);
    end
    else if (P <= Length(Pattern)) and (Pattern[P] = '*') then
    begin
      StarP := P;
      StarN := N;
      Inc(P);
    end
    else if StarP > 0 then
    begin
      P := StarP + 1;
      Inc(StarN);
      N := StarN;
    end
    else
      Exit(False);
  end;
  while (P <= Length(Pattern)) and (Pattern[P] = '*') do
    Inc(P);
  Result := P > Length(Pattern);
end;

procedure SdWriteDate(M: TPSPMemory; Address: Cardinal; T: TDateTime);
begin
  var Y, Mo, D, H, Mi, S, Ms: Word;
  DecodeDate(T, Y, Mo, D);
  DecodeTime(T, H, Mi, S, Ms);
  M.Write16(Address, Y);
  M.Write16(Address + 2, Mo);
  M.Write16(Address + 4, D);
  M.Write16(Address + 6, H);
  M.Write16(Address + 8, Mi);
  M.Write16(Address + 10, S);
  M.Write32(Address + 12, Cardinal(Ms) * 1000);
end;

function SdLoadSfo(const Dir: string; Sfo: TPSPSFO): Boolean;
begin
  var Name := TPath.Combine(Dir, 'PARAM.SFO');
  Result := TFile.Exists(Name) and Sfo.Load(TFile.ReadAllBytes(Name));
end;

function SdListIndex(const L: TBytes; const Name: string): Integer;
begin
  var I := 0;
  while I + 32 <= Length(L) do
  begin
    var N := 0;
    while (N < 13) and (L[I + N] <> 0) do
      Inc(N);
    if (N > 0) and SameText(TEncoding.ASCII.GetString(L, I, N), Name) then
      Exit(I);
    Inc(I, 32);
  end;
  Result := -1;
end;

function SdIsSecure(Sfo: TPSPSFO; const Name: string): Boolean;
begin
  Result := SdListIndex(Sfo.GetBytes('SAVEDATA_FILE_LIST'), Name) >= 0;
end;

function SdSecureTag(Sfo: TPSPSFO; const Name: string): TBytes;
begin
  var L := Sfo.GetBytes('SAVEDATA_FILE_LIST');
  var I := SdListIndex(L, Name);
  if I < 0 then
    Exit(nil);
  Result := Copy(L, I + 13, 16);
end;

// Lists Name as a secure file with its tag, or takes it off the list.
function SdSetSecure(Sfo: TPSPSFO; const Name: string; const Tag: TBytes; Secure: Boolean): Boolean;
begin
  var L := Sfo.GetBytes('SAVEDATA_FILE_LIST');
  var Old := Copy(L);
  if Length(L) < SfoFileListSize then
    SetLength(L, SfoFileListSize);
  var I := SdListIndex(L, Name);
  if I >= 0 then
    FillChar(L[I], 32, 0);
  if Secure then
  begin
    if I < 0 then
    begin
      I := 0;
      while (I + 32 <= Length(L)) and (L[I] <> 0) do
        Inc(I, 32);
    end;
    if I + 32 <= Length(L) then
    begin
      var B := TEncoding.ASCII.GetBytes(Name);
      Move(B[0], L[I], Min(Length(B), 12));
      if Length(Tag) >= 16 then
        Move(Tag[0], L[I + 13], 16);
    end;
  end;
  Sfo.SetBytes('SAVEDATA_FILE_LIST', L, SfoFileListSize);
  Result := (Length(Old) <> Length(L)) or not CompareMem(@Old[0], @L[0], Length(L));
end;

function SdTag(const Key, Data: TBytes): TBytes;
begin
  var H := THashMD5.Create;
  H.Update(Key);
  if Length(Data) > 0 then
    H.Update(Data);
  Result := H.HashAsBytes;
end;

{ TSavedataRunner }

function TSavedataRunner.Dir(const Name: string): string;
begin
  if Root = '' then
    raise ESaveName.Create('No memory stick');
  // The SDK's <> save-name marker names the game directory without a suffix.
  var Suffix := Name;
  if Suffix = '<>' then
    Suffix := '';
  // A name the memory stick cannot hold names no save.
  for var C in GameName + Suffix do
    if CharInSet(C, ['<', '>', ':', '"', '|', '?', '*', '\', '/']) or (C < ' ') then
      raise ESaveName.Create(Name);
  Result := TPath.Combine(Root, GameName + Suffix);
end;

function TSavedataRunner.ModeByte(V: Integer): Byte;
begin
  // Programs built for 3.00 and later get the newer protection by default.
  var Newer := Kernel.CompiledSdkVersion >= $03000000;
  case V of
    1:
      Result := $01;
    2:
      Result := $21;
    3:
      if Newer then
        Result := $41
      else
        Result := $01;
  else
    if Newer then
      Result := $41
    else
      Result := $21;
  end;
end;

function TSavedataRunner.ParamOk: Boolean;
begin
  if not HasVersion then
    Exit(True);
  if (SecureVersion < 0) or (SecureVersion > 3) then
    Exit(False);
  // Without a key only the unprotected mode works.
  Result := HasKey or (SecureVersion = 1);
end;

function TSavedataRunner.Listed: TArray<string>;
begin
  Result := nil;
  var L := M.Read32(P + SdSaveNameList);
  if L = 0 then
    Exit;
  for var I := 0 to 99 do
  begin
    var S := M.ReadString(L + Cardinal(I) * 20, 20);
    if S = '' then
      Break;
    Result := Result + [S];
  end;
end;

function TSavedataRunner.FirstExisting(out Name: string): Boolean;
begin
  for var S in Listed do
    try
      if TDirectory.Exists(Dir(S)) then
      begin
        Name := S;
        Exit(True);
      end;
    except
      on ESaveName do
        ;
    end;
  Name := SaveName;
  Result := False;
end;

function TSavedataRunner.NowTime: TDateTime;
begin
  // The wall clock the RTC shows: 2026-01-01 plus guest time, local.
  Result := EncodeDate(2026, 1, 1) + (Kernel.Scheduler.Now / 86400e9) + (PSPSettings.Timezone + 60 *
    PSPSettings.DaylightSaving) / 1440;
end;

procedure TSavedataRunner.Stamp(const Path: string);
begin
  try
    var T := NowTime;
    if TDirectory.Exists(Path) then
    begin
      TDirectory.SetCreationTime(Path, T);
      TDirectory.SetLastWriteTime(Path, T);
    end
    else
    begin
      TFile.SetCreationTime(Path, T);
      TFile.SetLastWriteTime(Path, T);
    end;
  except
    on E: EInOutError do
      ;
  end;
  IO.HostChanged(Path);
end;

procedure TSavedataRunner.ReadGuest(Address, Size: Cardinal; out Data: TBytes);
begin
  SetLength(Data, Size);
  if Size > 0 then
    M.ReadBytes(Address, Data[0], Size);
end;

procedure TSavedataRunner.LoadIcons(const D: string);
begin
  for var I := 0 to 3 do
  begin
    var F := P + SdIcon0 + Cardinal(I) * 16;
    var Buf := M.Read32(F);
    var BufSize := M.Read32(F + 4);
    var Name := TPath.Combine(D, SdSystemFiles[I + 1]);
    if (Buf = 0) or not TFile.Exists(Name) then
      Continue;
    var Data := TFile.ReadAllBytes(Name);
    var N := Min(Cardinal(Length(Data)), BufSize);
    if N > 0 then
      M.WriteBytes(Buf, Data[0], N);
    M.Write32(F + 8, N);
  end;
end;

procedure TSavedataRunner.SaveIcons(const D: string);
begin
  for var I := 0 to 3 do
  begin
    var F := P + SdIcon0 + Cardinal(I) * 16;
    var Buf := M.Read32(F);
    var N := M.Read32(F + 8);
    if (Buf = 0) or (N = 0) then
      Continue;
    var Data: TBytes;
    ReadGuest(Buf, N, Data);
    var Name := TPath.Combine(D, SdSystemFiles[I + 1]);
    TFile.WriteAllBytes(Name, Data);
    Stamp(Name);
  end;
end;

procedure TSavedataRunner.FillSfoParam(Sfo: TPSPSFO);
begin
  M.WriteString(P + SdTitle, UTF8Encode(Sfo.GetString('TITLE')), $80);
  M.WriteString(P + SdSavedataTitle, UTF8Encode(Sfo.GetString('SAVEDATA_TITLE')), $80);
  M.WriteString(P + SdDetail, UTF8Encode(Sfo.GetString('SAVEDATA_DETAIL')), $400);
  M.Write8(P + SdParental, Cardinal(Sfo.GetInt('PARENTAL_LEVEL')));
end;

function TSavedataRunner.WriteSave(const Name: string; Secure, NeedExisting: Boolean; out Res: Cardinal): Boolean;
begin
  Res := 0;
  var D := Dir(Name);
  var Sfo := TPSPSFO.Create;
  try
    var HadSfo := SdLoadSfo(D, Sfo);
    if NeedExisting then
    begin
      if not TDirectory.Exists(D) then
      begin
        Res := SD_RW_NO_DATA;
        Exit(False);
      end;
      if not HadSfo then
      begin
        Res := SD_RW_BROKEN;
        Exit(False);
      end;
    end;
    if not TDirectory.Exists(D) then
    begin
      ForceDirectories(D);
      Stamp(D);
    end;
    var Rewrite := not NeedExisting or Secure;
    if Rewrite then
    begin
      Sfo.SetString('CATEGORY', 'MS', 4);
      Sfo.SetInt('PARENTAL_LEVEL', M.Read8(P + SdParental));
      Sfo.SetString('SAVEDATA_DETAIL', UTF8ToString(M.ReadAnsi(P + SdDetail, $400)), $400);
      Sfo.SetString('SAVEDATA_DIRECTORY', ExtractFileName(D), $40);
      Sfo.SetString('SAVEDATA_TITLE', UTF8ToString(M.ReadAnsi(P + SdSavedataTitle, $80)), $80);
      Sfo.SetString('TITLE', UTF8ToString(M.ReadAnsi(P + SdTitle, $80)), $80);
      var Params := Sfo.GetBytes('SAVEDATA_PARAMS');
      SetLength(Params, SfoParamsSize);
      Params[0] := ModeByte(SecureVersion);
      Sfo.SetBytes('SAVEDATA_PARAMS', Params, SfoParamsSize);
      if not Sfo.Has('SAVEDATA_FILE_LIST') then
        SdSetSecure(Sfo, '', nil, False);
    end;
    if FileName <> '' then
    begin
      var Data: TBytes;
      ReadGuest(M.Read32(P + SdDataBuf), M.Read32(P + SdDataSize), Data);
      var FilePath := TPath.Combine(D, FileName);
      TFile.WriteAllBytes(FilePath, Data);
      Stamp(FilePath);
      if SdSetSecure(Sfo, FileName, SdTag(Key, Data), Secure) then
        Rewrite := True;
    end;
    if not NeedExisting then
      SaveIcons(D);
    if Rewrite then
    begin
      var SfoPath := TPath.Combine(D, 'PARAM.SFO');
      TFile.WriteAllBytes(SfoPath, Sfo.Save);
      Stamp(SfoPath);
    end;
    Result := True;
  finally
    Sfo.Free;
  end;
end;

function TSavedataRunner.DeleteSave(const Name: string): Boolean;
begin
  var D := Dir(Name);
  if not TDirectory.Exists(D) then
    Exit(False);
  for var F in TDirectory.GetFiles(D) do
  begin
    TFile.Delete(F);
    IO.HostChanged(F);
  end;
  TDirectory.Delete(D, True);
  IO.HostChanged(D);
  Result := True;
end;

function TSavedataRunner.Load: Cardinal;
begin
  var Name := SaveName;
  if (Mode = 4) and not Selected then
    FirstExisting(Name);
  if not ParamOk then
    Exit(SD_LOAD_PARAM);
  var D := Dir(Name);
  if not TDirectory.Exists(D) then
    Exit(SD_LOAD_NO_DATA);
  var Sfo := TPSPSFO.Create;
  try
    if not SdLoadSfo(D, Sfo) then
      Exit(SD_LOAD_BROKEN);
    if Mode = 4 then
      M.WriteString(P + SdSaveName, RawByteString(Name), 20);
    FillSfoParam(Sfo);
    LoadIcons(D);
    if FileName = '' then
      Exit(0);
    var FilePath := TPath.Combine(D, FileName);
    if not TFile.Exists(FilePath) then
      Exit(SD_LOAD_NO_FILE);
    var Data := TFile.ReadAllBytes(FilePath);
    if SdIsSecure(Sfo, FileName) then
    begin
      var Params := Sfo.GetBytes('SAVEDATA_PARAMS');
      if (Length(Params) = 0) or (Params[0] <> ModeByte(SecureVersion)) then
        Exit(SD_LOAD_BROKEN);
      var Tag := SdSecureTag(Sfo, FileName);
      var Expected := SdTag(Key, Data);
      if SdKeyIsSet(Tag) and not CompareMem(@Tag[0], @Expected[0], 16) then
        Exit(SD_LOAD_BROKEN);
    end;
    var N := Min(Cardinal(Length(Data)), M.Read32(P + SdDataBufSize));
    if N > 0 then
      M.WriteBytes(M.Read32(P + SdDataBuf), Data[0], N);
    M.Write32(P + SdDataSize, N);
    Result := 0;
  finally
    Sfo.Free;
  end;
end;

function TSavedataRunner.Read(Secure: Boolean): Cardinal;
begin
  if Secure and not ParamOk then
    Exit(SD_RW_PARAM);
  var D := Dir(SaveName);
  if not TDirectory.Exists(D) then
    Exit(SD_RW_NO_DATA);
  var Sfo := TPSPSFO.Create;
  try
    if not SdLoadSfo(D, Sfo) then
      Exit(SD_RW_BROKEN);
    if FileName = '' then
      Exit(0);
    var FilePath := TPath.Combine(D, FileName);
    if not TFile.Exists(FilePath) then
      Exit(SD_RW_NO_FILE);
    var Data := TFile.ReadAllBytes(FilePath);
    if SdIsSecure(Sfo, FileName) then
    begin
      // A protected file only opens through the secure modes.
      if not Secure then
        Exit(SD_RW_BROKEN);
      var Params := Sfo.GetBytes('SAVEDATA_PARAMS');
      if (Length(Params) = 0) or (Params[0] <> ModeByte(SecureVersion)) then
        Exit(SD_RW_BROKEN);
    end;
    var N := Min(Cardinal(Length(Data)), M.Read32(P + SdDataBufSize));
    if N > 0 then
      M.WriteBytes(M.Read32(P + SdDataBuf), Data[0], N);
    M.Write32(P + SdDataSize, N);
    Result := 0;
  finally
    Sfo.Free;
  end;
end;

function TSavedataRunner.Save: Cardinal;
begin
  var Name := SaveName;
  if (Mode = 5) and not Selected then
  begin
    var L := Listed;
    if Length(L) > 0 then
      Name := L[0];
  end;
  if not ParamOk then
    Exit(SD_SAVE_PARAM);
  WriteSave(Name, HasKey, False, Result);
  if Mode = 5 then
    M.WriteString(P + SdSaveName, RawByteString(Name), 20);
end;

function TSavedataRunner.Make(Secure: Boolean): Cardinal;
begin
  if Secure and not ParamOk then
    Exit(SD_RW_PARAM);
  WriteSave(SaveName, Secure and HasKey, False, Result);
end;

function TSavedataRunner.Write(Secure: Boolean): Cardinal;
begin
  if Secure and not ParamOk then
    Exit(SD_RW_PARAM);
  WriteSave(SaveName, Secure and HasKey, True, Result);
end;

function TSavedataRunner.Erase: Cardinal;
begin
  var D := Dir(SaveName);
  if not TDirectory.Exists(D) then
    Exit(SD_RW_NO_DATA);
  var Sfo := TPSPSFO.Create;
  try
    if not SdLoadSfo(D, Sfo) then
      Exit(SD_RW_BROKEN);
    if FileName = '' then
      Exit(0);
    var FilePath := TPath.Combine(D, FileName);
    if not TFile.Exists(FilePath) then
      Exit(SD_RW_NO_FILE);
    TFile.Delete(FilePath);
    IO.HostChanged(FilePath);
    if SdSetSecure(Sfo, FileName, nil, False) then
    begin
      TFile.WriteAllBytes(TPath.Combine(D, 'PARAM.SFO'), Sfo.Save);
      Stamp(TPath.Combine(D, 'PARAM.SFO'));
    end;
    Result := 0;
  finally
    Sfo.Free;
  end;
end;

function TSavedataRunner.Sizes: Cardinal;
begin
  var Free := M.Read32(P + SdMsFree);
  if Free <> 0 then
  begin
    M.Write32(Free, SdClusterSize);
    M.Write32(Free + 4, SdFreeClusters);
    M.Write32(Free + 8, SdFreeKB);
    M.WriteString(Free + 12, SdSizeString(SdFreeKB), 8);
  end;
  var Info := M.Read32(P + SdMsData);
  if Info <> 0 then
  begin
    var Clusters: Int64 := 0;
    var Saved := GameName;
    try
      GameName := M.ReadString(Info, 16);
      var D := Dir(M.ReadString(Info + 16, 20));
      if TDirectory.Exists(D) then
        Clusters := SdUsedClusters(D);
    except
      on ESaveName do
        ;
    end;
    GameName := Saved;
    var KB := Clusters * (SdClusterSize div 1024);
    M.Write32(Info + 36, Cardinal(Clusters));
    M.Write32(Info + 40, Cardinal(KB));
    M.WriteString(Info + 44, SdSizeString(KB), 8);
    M.Write32(Info + 52, Cardinal(KB));
    M.WriteString(Info + 56, SdSizeString(KB), 8);
  end;
  var Need := M.Read32(P + SdUtilityData);
  if Need <> 0 then
  begin
    // The data file, PARAM.SFO, the pictures and sounds, and the folder.
    var Clusters: Int64 := 2;
    if FileName <> '' then
      Inc(Clusters, SdClusters(M.Read32(P + SdDataSize)));
    for var I := 0 to 3 do
      Inc(Clusters, SdClusters(M.Read32(P + SdIcon0 + Cardinal(I) * 16 + 8)));
    var KB := Clusters * (SdClusterSize div 1024);
    M.Write32(Need, Cardinal(Clusters));
    M.Write32(Need + 4, Cardinal(KB));
    M.WriteString(Need + 8, SdSizeString(KB), 8);
    M.Write32(Need + 16, Cardinal(KB));
    M.WriteString(Need + 20, SdSizeString(KB), 8);
  end;
  Result := 0;
end;

function TSavedataRunner.List: Cardinal;
begin
  var L := M.Read32(P + SdIdList);
  if L = 0 then
    Exit(0);
  var Max := Integer(M.Read32(L));
  var Entries := M.Read32(L + 8);
  var Names := TDirectory.GetDirectories(Root);
  TArray.Sort<string>(Names);
  var Count := 0;
  for var N in Names do
  begin
    if Count >= Max then
      Break;
    var Folder := ExtractFileName(N);
    if not Folder.ToUpper.StartsWith(GameName.ToUpper) then
      Continue;
    var Rest := Folder.Substring(Length(GameName));
    if not SdMatch(SaveName, Rest) then
      Continue;
    var E := Entries + Cardinal(Count) * 72;
    var T := TDirectory.GetLastWriteTime(N);
    M.Write32(E, $11FF);
    SdWriteDate(M, E + 4, TDirectory.GetCreationTime(N));
    SdWriteDate(M, E + 20, T);
    SdWriteDate(M, E + 36, T);
    M.WriteString(E + 52, RawByteString(Rest), 20);
    Inc(Count);
  end;
  M.Write32(L + 4, Cardinal(Count));
  Result := 0;
end;

function TSavedataRunner.Files: Cardinal;
begin
  var D := Dir(SaveName);
  if not TDirectory.Exists(D) then
    Exit(SD_RW_NO_DATA);
  var Sfo := TPSPSFO.Create;
  try
    if not SdLoadSfo(D, Sfo) then
      Exit(SD_RW_BROKEN);
    var L := M.Read32(P + SdFileList);
    if L <> 0 then
    begin
      var Max: array[0..2] of Integer;
      var Base: array[0..2] of Cardinal;
      var Count: array[0..2] of Integer;
      for var K := 0 to 2 do
      begin
        Max[K] := Integer(M.Read32(L + Cardinal(K) * 4));
        Base[K] := M.Read32(L + 24 + Cardinal(K) * 4);
        Count[K] := 0;
      end;
      for var F in SdFiles(D) do
      begin
        // 0 secure, 1 normal, 2 system.
        var K := 1;
        for var S in SdSystemFiles do
          if F.Name = S then
            K := 2;
        if (K = 1) and SdIsSecure(Sfo, F.Name) then
          K := 0;
        if (Count[K] >= Max[K]) or (Base[K] = 0) then
          Continue;
        var E := Base[K] + Cardinal(Count[K]) * 80;
        M.Write32(E, $21FF);
        M.Write32(E + 8, Cardinal(F.Size));
        M.Write32(E + 12, Cardinal(F.Size shr 32));
        SdWriteDate(M, E + 16, F.Time);
        SdWriteDate(M, E + 32, F.Time);
        SdWriteDate(M, E + 48, F.Time);
        M.WriteString(E + 64, RawByteString(F.Name), 16);
        Inc(Count[K]);
      end;
      M.Write32(L + 12, Cardinal(Count[0]));
      M.Write32(L + 16, Cardinal(Count[1]));
      M.Write32(L + 20, Cardinal(Count[2]));
    end;
    M.Write32(P + SdBind, $3FD);
    Result := 0;
  finally
    Sfo.Free;
  end;
end;

function TSavedataRunner.GetSize: Cardinal;
begin
  var S := M.Read32(P + SdSizeInfo);
  if S = 0 then
    Exit(0);
  M.Write32(S + 16, SdClusterSize);
  M.Write32(S + 20, SdFreeClusters);
  M.Write32(S + 24, SdFreeKB);
  M.WriteString(S + 28, SdSizeString(SdFreeKB), 8);
  var NumSecure := Integer(M.Read32(S));
  var NumNormal := Integer(M.Read32(S + 4));
  if NumSecure + NumNormal > 0 then
  begin
    var Clusters: Int64 := 2;
    for var K := 0 to 1 do
    begin
      var Count := NumSecure;
      if K = 1 then
        Count := NumNormal;
      var Entries := M.Read32(S + 8 + Cardinal(K) * 4);
      for var I := 0 to Count - 1 do
      begin
        var E := Entries + Cardinal(I) * 24;
        Inc(Clusters, SdClusters(Int64(UInt64(M.Read32(E)) or (UInt64(M.Read32(E + 4)) shl 32))));
      end;
    end;
    // What the stick lacks for a new save and for rewriting the existing one:
    // nothing while there is room (programs take any other value as "full").
    var D := Dir(SaveName);
    var Existing: Int64 := 0;
    if TDirectory.Exists(D) then
      Existing := SdUsedClusters(D);
    var Lack := System.Math.Max(0, Clusters - SdFreeClusters) * (SdClusterSize div 1024);
    var LackOver := System.Math.Max(0, Clusters - Existing - SdFreeClusters) * (SdClusterSize div 1024);
    M.Write32(S + 36, Cardinal(Lack));
    M.WriteString(S + 40, SdSizeString(Lack), 8);
    M.Write32(S + 48, Cardinal(LackOver));
    M.WriteString(S + 52, SdSizeString(LackOver), 8);
  end;
  Result := 0;
end;

function TSavedataRunner.Run: Cardinal;
begin
  try
    Result := RunMode;
  except
    on ESaveName do
      case Mode of
        0, 2, 4:
          Result := SD_LOAD_NO_DATA;
        1, 3, 5:
          Result := SD_SAVE_PARAM;
        6, 7, 9, 10, 21:
          Result := SD_DELETE_NO_DATA;
        8, 11, 22:
          Result := 0;
      else
        Result := SD_RW_NO_DATA;
      end;
  end;
end;

function TSavedataRunner.RunMode: Cardinal;
begin
  if Root = '' then
    case Mode of
      0, 2, 4:
        Exit(SD_LOAD_NO_MS);
      1, 3, 5:
        Exit(SD_SAVE_NO_MS);
      6, 7, 9, 10:
        Exit(SD_DELETE_NO_MS);
      8:
        Exit(SD_SIZES_NO_MS);
    else
      Exit(SD_RW_NO_MS);
    end;
  case Mode of
    0, 2, 4:
      Result := Load;
    1, 3, 5:
      Result := Save;
    6:
      begin
        if Selected then
        begin
          if DeleteSave(SaveName) then
            Exit(0);
        end
        else
        begin
          var Name: string;
          if FirstExisting(Name) then
            DeleteSave(Name);
        end;
        Result := SD_DELETE_NO_DATA;
      end;
    7:
      begin
        Result := 0;
        for var Name in Listed do
          try
            if DeleteSave(Name) then
              Inc(Result);
          except
            on ESaveName do
              ;
          end;
      end;
    8:
      Result := Sizes;
    9, 10, 21:
      if DeleteSave(SaveName) then
        Result := 0
      else
        Result := SD_DELETE_NO_DATA;
    11:
      Result := List;
    12:
      Result := Files;
    13:
      Result := Make(True);
    14:
      Result := Make(False);
    15:
      Result := Read(True);
    16:
      Result := Read(False);
    17:
      Result := Write(True);
    18:
      Result := Write(False);
    19, 20:
      Result := Erase;
    22:
      Result := GetSize;
  else
    Result := SD_LOAD_PARAM;
  end;
end;

procedure TPSPUtility.StepSavedata(D: TPSPDialog);
begin
  if D.Done then
    Exit;
  var R := TSavedataRunner.Create;
  try
    var P := D.Params;
    R.M := FMemory;
    R.Kernel := FKernel;
    R.IO := FSystem.IO;
    R.P := P;
    R.Size := D.Size;
    R.Mode := Integer(FMemory.Read32(P + SdMode));
    R.GameName := FMemory.ReadString(P + SdGameName, 13);
    R.SaveName := FMemory.ReadString(P + SdSaveName, 20);
    R.FileName := FMemory.ReadString(P + SdFileName, 13);
    SetLength(R.Key, 16);
    FillChar(R.Key[0], 16, 0);
    if R.Size > SdKey then
      FMemory.ReadBytes(P + SdKey, R.Key[0], 16);
    R.HasKey := SdKeyIsSet(R.Key);
    R.HasVersion := R.Size >= $600;
    R.SecureVersion := 0;
    if R.HasVersion then
      R.SecureVersion := Integer(FMemory.Read32(P + SdSecureVersion));
    R.Root := '';
    if FSystem.IO.MemstickInserted and (FSystem.IO.MemstickRoot <> '') then
    begin
      R.Root := TPath.Combine(FSystem.IO.MemstickRoot, 'PSP' + PathDelim + 'SAVEDATA');
      ForceDirectories(R.Root);
    end;
    if Interactive and (R.Mode >= 2) and (R.Mode <= 6) then
    begin
      if D.Stage = 0 then
      begin
        var Candidates: TArray<string>;
        if R.Mode in [4, 5, 6] then
          Candidates := R.Listed;
        if Length(Candidates) = 0 then
          Candidates := [R.SaveName];
        for var Name in Candidates do
          try
            if (R.Mode in [3, 5]) or TDirectory.Exists(R.Dir(Name)) then
              D.Choices := D.Choices + [Name];
          except
            on ESaveName do
              ;
          end;
        case R.Mode of
          2, 4:
            D.Text := 'Select saved data to load.';
          3, 5:
            D.Text := 'Select where to save this data.';
          6:
            D.Text := 'Select saved data to delete.';
        end;
        if Length(D.Choices) = 0 then
          D.Text := 'There is no saved data.';
        D.Stage := 1;
      end;
      var B := Pressed(D);
      if (B and CancelButton) <> 0 then
      begin
        FMemory.Write32(P + DialogResult, 1);
        D.Done := True;
        Finish(D);
        Exit;
      end;
      if D.Stage = 1 then
      begin
        if (B and PSP_CTRL_UP) <> 0 then
          D.Selection := Max(0, D.Selection - 1);
        if (B and PSP_CTRL_DOWN) <> 0 then
          D.Selection := Min(Max(0, High(D.Choices)), D.Selection + 1);
      end;
      if (B and ConfirmButton) = 0 then
        Exit;
      if Length(D.Choices) = 0 then
      begin
        if R.Mode = 6 then
          FMemory.Write32(P + DialogResult, SD_DELETE_NO_DATA)
        else
          FMemory.Write32(P + DialogResult, SD_LOAD_NO_DATA);
        D.Done := True;
        Finish(D);
        Exit;
      end;
      R.SaveName := D.Choices[D.Selection];
      R.Selected := True;
      FMemory.WriteString(P + SdSaveName, RawByteString(R.SaveName), 20);
      if D.Stage = 1 then
      begin
        var Overwrite := False;
        if R.Mode in [3, 5] then
          try
            Overwrite := TDirectory.Exists(R.Dir(R.SaveName));
          except
            on ESaveName do
              ;
          end;
        if Overwrite or (R.Mode = 6) then
        begin
          D.Stage := 2;
          if R.Mode = 6 then
            D.Text := 'Delete this saved data? This cannot be undone.'
          else
            D.Text := 'Overwrite this saved data?';
          Exit;
        end;
      end;
    end;
    D.Done := True;
    var Res: Cardinal;
    try
      Res := R.Run;
    except
      on E: EInOutError do
        Res := SD_RW_NO_MS;
      on E: EFileStreamError do
        Res := SD_RW_NO_MS;
    end;
    FMemory.Write32(P + DialogResult, Res);
    if FHLE.TraceCalls then
      FHLE.Log('utility: savedata mode %d -> %.8x', [R.Mode, Res]);
  finally
    R.Free;
  end;
  Finish(D);
end;

constructor TPSPUtility.Create(System: TPSPSystem);
begin
  inherited Create(System);
  for var K := Low(TPSPDialogType) to High(TPSPDialogType) do
  begin
    FDialogs[K] := TPSPDialog.Create;
    FDialogs[K].Kind := K;
  end;
  FModules := TList<Cardinal>.Create;
  FSoftwareView := TSoftwareDialogView.Create(System);
  FView := FSoftwareView;
end;

destructor TPSPUtility.Destroy;
begin
  FSoftwareView.Free;
  for var K := Low(TPSPDialogType) to High(TPSPDialogType) do
    FDialogs[K].Free;
  FModules.Free;
  inherited;
end;

procedure TPSPUtility.Reset;
begin
  FCurrent := dtNone;
  for var K := Low(TPSPDialogType) to High(TPSPDialogType) do
  begin
    var D := FDialogs[K];
    D.Status := PSPDialogNone;
    D.Params := 0;
    D.Updates := 0;
    D.Done := False;
  end;
  FHtmlStarted := False;
  FHtmlMemory := 0;
  FModules.Clear;
  FDelayWord := FKernel.AllocKernel(16, 'utility delay');
  FLastButtons := 0;
  FWorkStub := FKernel.AllocKernel(16, 'utility thread');
  FWorkThread := nil;
  FWorkUntil := 0;
end;

procedure TPSPUtility.Work(D: TPSPDialog; Ns: Int64);
begin
  // At the priority the program gave the dialog's threads.
  var Prio := 0;
  if D.Params <> 0 then
    for var K := 0 to 3 do
    begin
      var P := Integer(FMemory.Read32(D.Params + 12 + Cardinal(K * 4)));
      if (P > 0) and ((Prio = 0) or (P < Prio)) then
        Prio := P;
    end;
  if Prio = 0 then
    Exit;
  FWorkUntil := FKernel.Scheduler.Now + Ns;
  if (FWorkThread = nil) or (FKernel.ThreadById(FWorkThread.UID) <> FWorkThread) then
  begin
    // The thread loops on: syscall; j loop.
    FMemory.Write32(FWorkStub, (Cardinal(FWorkIndex) shl 6) or $0C);
    FMemory.Write32(FWorkStub + 4, (2 shl 26) or ((FWorkStub shr 2) and $03FFFFFF));
    FMemory.Write32(FWorkStub + 8, 0);
    FWorkThread := FKernel.CreateThread('SceUtilityDialog', FWorkStub, Prio, $800, 0, FSystem.CPU.Ctx.GPR[28]);
    if FWorkThread <> nil then
      FKernel.StartThread(FWorkThread, 0, 0);
    Exit;
  end;
  if FWorkThread.Priority <> Prio then
    FKernel.ChangePriority(FWorkThread, Prio);
  if FWorkThread.IsWaiting and (FWorkThread.Wait.HLETag = 'utility thread') then
    FKernel.EndWait(FWorkThread, 0);
end;

procedure TPSPUtility.hDialogThread;
begin
  var Left := FWorkUntil - FKernel.Scheduler.Now;
  if Left > 0 then
    // Busy: a slice of computing, then round again.
    FSystem.CPU.AddCycles(Integer(Min(Left, Int64(100000)) * FKernel.Scheduler.MHz div 1000))
  else
    FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, nil, nil, 'utility thread');
end;

function TPSPUtility.Dialog(Kind: TPSPDialogType): TPSPDialog;
begin
  Result := FDialogs[Kind];
end;

function TPSPUtility.Busy: Boolean;
begin
  Result := (FCurrent <> dtNone) and (FDialogs[FCurrent].Status <> PSPDialogNone);
end;

procedure TPSPUtility.Yield(Us: Cardinal);
begin
  if not FKernel.CanWait then
    Exit;
  FMemory.Write32(FDelayWord, Us);
  FKernel.BeginWait(PSPWaitDelay, nil, 0, FDelayWord, False, nil, nil, 'utility');
end;

procedure TPSPUtility.At(Delay: Int64; D: TPSPDialog; Phase: Integer);
begin
  FKernel.AddStateTimer(FKernel.Scheduler.Now + Delay, D, TPSPStateAction.Create(StateDialog, [D], [Phase]));
end;

procedure TPSPUtility.StateDialog(Action: TPSPStateAction; Value: Cardinal);
begin
  var D := TPSPDialog(Action.Obj(0));
  case Action.Arg(0) of
    0:
      EnterRunning(D);
    1:
      if D.Pumped then
        EnterRunning(D);
    2:
      if D.Status = PSPDialogShutdown then
        D.Status := PSPDialogNone;
    3:
      if D.Status = PSPDialogInit then
        D.Status := PSPDialogRunning;
    4:
      if D.Status = PSPDialogShutdown then
      begin
        D.Status := PSPDialogNone;
        if FHtmlMemory <> 0 then
          FKernel.UserPartition.FreeBlock(FHtmlMemory);
        FHtmlMemory := 0;
      end;
  else
    raise EReadError.Create('Invalid utility state phase');
  end;
end;

procedure TPSPUtility.EnterRunning(D: TPSPDialog);
begin
  if D.Status <> PSPDialogInit then
    Exit;
  D.Status := PSPDialogRunning;
  D.RunningAt := FKernel.Scheduler.Now;
  D.Updates := 0;
end;

procedure TPSPUtility.Finish(D: TPSPDialog);
begin
  D.Status := PSPDialogFinished;
end;

procedure TPSPUtility.InitStart(Kind: TPSPDialogType; const Sizes: array of Cardinal);
begin
  var P := FHLE.Arg(0);
  if Busy then
  begin
    FHLE.Result(SCE_UTILITY_ERROR_INVALID_STATUS);
    Exit;
  end;
  var Size: Cardinal := 0;
  if P <> 0 then
    Size := FMemory.Read32(P);
  var Ok := False;
  for var S in Sizes do
    if S = Size then
      Ok := True;
  if not Ok then
  begin
    FHLE.Result(SCE_UTILITY_ERROR_INVALID_PARAM_SIZE);
    Exit;
  end;
  FCurrent := Kind;
  var D := FDialogs[Kind];
  FKernel.CancelTimersOf(D);
  D.Status := PSPDialogInit;
  D.Params := P;
  D.Size := Size;
  D.Updates := 0;
  D.InitAt := FKernel.Scheduler.Now;
  D.Pumped := False;
  D.Aborted := False;
  D.Error := 0;
  D.Done := False;
  D.Selection := 0;
  D.Stage := 0;
  D.OskField := 0;
  D.Choices := nil;
  D.Text := '';
  FLastButtons := FSystem.Display.SampledButtons;
  if (Kind = dtMsg) and (Size > $23C) and ((FMemory.Read32(P + $23C) and $100) <> 0) then
    D.Selection := 1;
  FHLE.Result(0);
  if FHLE.TraceCalls then
    TraceStart(D);
  case Kind of
    dtMsg:
      begin
        CheckMsgParams(D);
        At(MsgPumpedInitNs, D, 1);
        At(MsgInitNs, D, 0);
      end;
  else
    At(SavedataInitNs, D, 0);
  end;
end;

procedure TPSPUtility.GetStatus(Kind: TPSPDialogType);
begin
  if FCurrent <> Kind then
    FHLE.Result(SCE_UTILITY_ERROR_WRONG_TYPE)
  else
    FHLE.Result(FDialogs[Kind].Status);
end;

procedure TPSPUtility.Update(Kind: TPSPDialogType);
begin
  if FCurrent <> Kind then
  begin
    FHLE.Result(SCE_UTILITY_ERROR_WRONG_TYPE);
    Exit;
  end;
  var D := FDialogs[Kind];
  if D.Status = PSPDialogInit then
    D.Pumped := True;
  if D.Status <> PSPDialogRunning then
  begin
    FHLE.Result(SCE_UTILITY_ERROR_INVALID_STATUS);
    Exit;
  end;
  Inc(D.Updates);
  FHLE.Result(0);
  Step(D);
  // Update hands the frame to the dialog's threads and waits for them.
  Yield(UpdateYieldUs);
end;

procedure TPSPUtility.ShutdownStart(Kind: TPSPDialogType);
begin
  if FCurrent <> Kind then
  begin
    FHLE.Result(SCE_UTILITY_ERROR_WRONG_TYPE);
    Exit;
  end;
  var D := FDialogs[Kind];
  if D.Status <> PSPDialogFinished then
  begin
    FHLE.Result(SCE_UTILITY_ERROR_INVALID_STATUS);
    Exit;
  end;
  FHLE.Result(0);
  D.Status := PSPDialogShutdown;
  var Delay: Int64 := DialogShutdownNs;
  if Kind = dtSavedata then
  begin
    // Savedata shuts down on the utility thread; a caller it preempts finds it done.
    if (FKernel.Current <> nil) and (FKernel.Current.Priority > UtilityThreadPriority) then
    begin
      D.Status := PSPDialogNone;
      Exit;
    end;
    Delay := SavedataShutdownNs;
  end
  else
    // Its threads spend part of the shutdown computing.
    Work(D, DialogShutdownWorkNs);
  At(Delay, D, 2);
end;

procedure TPSPUtility.Step(D: TPSPDialog);
begin
  case D.Kind of
    dtMsg:
      StepMsg(D);
    dtSavedata:
      StepSavedata(D);
    dtOsk:
      StepOsk(D);
  else
    StepOther(D);
  end;
end;

procedure TPSPUtility.TraceStart(D: TPSPDialog);
begin
  var P := D.Params;
  case D.Kind of
    dtMsg:
      FHLE.Log('utility: message dialog mode %d error %.8x options %x "%s"',
        [ FMemory.Read32(P + $34), FMemory.Read32(P + $38), FMemory.Read32(P + $23C), UTF8ToString(FMemory.ReadAnsi(P +
        $3C, 512)).Replace(#10, '|')]);
    dtSavedata:
      FHLE.Log('utility: savedata mode %d game "%s" save "%s" file "%s"',
        [ FMemory.Read32(P + $30), FMemory.ReadString(P + $3C, 13), FMemory.ReadString(P + $4C, 20),
        FMemory.ReadString(P + $64, 13)]);
  else
    FHLE.Log('utility: dialog %d size %x', [Ord(D.Kind), D.Size]);
  end;
end;

function TPSPUtility.Interactive: Boolean;
begin
  Result := (FView <> nil) and ((FView <> FSoftwareView) or FSystem.IO.HasDisplay);
end;

function TPSPUtility.ConfirmButton: Cardinal;
begin
  if PSPSettings.ButtonSwap = 0 then
    Result := PSP_CTRL_CIRCLE
  else
    Result := PSP_CTRL_CROSS;
end;

function TPSPUtility.CancelButton: Cardinal;
begin
  if PSPSettings.ButtonSwap = 0 then
    Result := PSP_CTRL_CROSS
  else
    Result := PSP_CTRL_CIRCLE;
end;

function TPSPUtility.Pressed(D: TPSPDialog): Cardinal;
begin
  Result := 0;
  if not Interactive then
    Exit;
  var Buttons := FView.Update(D, FMemory);
  Result := Buttons and not FLastButtons;
  FLastButtons := Buttons;
end;

{ Message dialog, OSK and the rest: PSP.Utility.Dialogs.inc }

procedure TPSPUtility.Register;
const
  U = 'sceUtility';
begin
  var H := FHLE;
  H.Register('RetroMulUtility', 1, 'UtilityDialogThread', hDialogThread);
  FWorkIndex := H.Find('RetroMulUtility', 1);
  H.Register(U, $2AD8E239, 'sceUtilityMsgDialogInitStart', hMsgInitStart);
  H.Register(U, $9A1C91D7, 'sceUtilityMsgDialogGetStatus', hMsgGetStatus);
  H.Register(U, $95FC253B, 'sceUtilityMsgDialogUpdate', hMsgUpdate);
  H.Register(U, $67AF3428, 'sceUtilityMsgDialogShutdownStart', hMsgShutdownStart);
  H.Register(U, $4928BD96, 'sceUtilityMsgDialogAbort', hMsgAbort);
  H.Register(U, $50C4CD57, 'sceUtilitySavedataInitStart', hSavedataInitStart);
  H.Register(U, $8874DBE0, 'sceUtilitySavedataGetStatus', hSavedataGetStatus);
  H.Register(U, $D4B95FFB, 'sceUtilitySavedataUpdate', hSavedataUpdate);
  H.Register(U, $9790B33C, 'sceUtilitySavedataShutdownStart', hSavedataShutdownStart);
  H.Register(U, $F6269B82, 'sceUtilityOskInitStart', hOskInitStart);
  H.Register(U, $F3F76017, 'sceUtilityOskGetStatus', hOskGetStatus);
  H.Register(U, $4B85C861, 'sceUtilityOskUpdate', hOskUpdate);
  H.Register(U, $3DFAEBA9, 'sceUtilityOskShutdownStart', hOskShutdownStart);
  H.Register(U, $4DB1E739, 'sceUtilityNetconfInitStart', hNetconfInitStart);
  H.Register(U, $6332AA39, 'sceUtilityNetconfGetStatus', hNetconfGetStatus);
  H.Register(U, $91E70E35, 'sceUtilityNetconfUpdate', hNetconfUpdate);
  H.Register(U, $F88155F6, 'sceUtilityNetconfShutdownStart', hNetconfShutdownStart);
  H.Register(U, $C492F751, 'sceUtilityGameSharingInitStart', hSharingInitStart);
  H.Register(U, $946963F3, 'sceUtilityGameSharingGetStatus', hSharingGetStatus);
  H.Register(U, $7853182D, 'sceUtilityGameSharingUpdate', hSharingUpdate);
  H.Register(U, $EFC6F80F, 'sceUtilityGameSharingShutdownStart', hSharingShutdownStart);
  H.Register(U, $0251B134, 'sceUtilityScreenshotInitStart', hScreenshotInitStart);
  H.Register(U, $D81957B7, 'sceUtilityScreenshotGetStatus', hScreenshotGetStatus);
  H.Register(U, $AB083EA9, 'sceUtilityScreenshotUpdate', hScreenshotUpdate);
  H.Register(U, $F9E0008C, 'sceUtilityScreenshotShutdownStart', hScreenshotShutdownStart);
  H.Register(U, $86A03A27, 'sceUtilityScreenshotContStart', hScreenshotContStart);
  H.Register(U, $24AC31EB, 'sceUtilityGamedataInstallInitStart', hInstallInitStart);
  H.Register(U, $B57E95D9, 'sceUtilityGamedataInstallGetStatus', hInstallGetStatus);
  H.Register(U, $16D02AF0, 'sceUtilityNpSigninInitStart', hNpSigninInitStart);
  H.Register(U, $86ABDB1B, 'sceUtilityNpSigninGetStatus', hNpSigninGetStatus);
  H.Register(U, $F3FBC572, 'sceUtilityNpSigninUpdate', hNpSigninUpdate);
  H.Register(U, $E19C97D6, 'sceUtilityNpSigninShutdownStart', hNpSigninShutdownStart);
  H.Register(U, $CDC3AA41, 'sceUtilityHtmlViewerInitStart', hHtmlInitStart);
  H.Register(U, $BDA7D894, 'sceUtilityHtmlViewerGetStatus', hHtmlGetStatus);
  H.Register(U, $05AFB9E4, 'sceUtilityHtmlViewerUpdate', hHtmlUpdate);
  H.Register(U, $F5CE1134, 'sceUtilityHtmlViewerShutdownStart', hHtmlShutdownStart);
  H.Register(U, $A5DA2406, 'sceUtilityGetSystemParamInt', hGetSystemParamInt);
  H.Register(U, $34B78343, 'sceUtilityGetSystemParamString', hGetSystemParamString);
  H.Register(U, $45C18506, 'sceUtilitySetSystemParamInt', hSetSystemParamInt);
  H.Register(U, $41E30674, 'sceUtilitySetSystemParamString', hSetSystemParamString);
  H.Register(U, $5EEE6548, 'sceUtilityCheckNetParam', hCheckNetParam);
  H.Register(U, $434D4B3A, 'sceUtilityGetNetParam', hGetNetParam);
  H.Register(U, $2A2B3DE0, 'sceUtilityLoadModule', hLoadModule);
  H.Register(U, $E49BFE92, 'sceUtilityUnloadModule', hUnloadModule);
  H.Register(U, $1579A159, 'sceUtilityLoadNetModule', hLoadNetModule);
  H.Register(U, $64D50C56, 'sceUtilityUnloadNetModule', hUnloadNetModule);
  H.Register(U, $C629AF26, 'sceUtilityLoadAvModule', hLoadAvModule);
  H.Register(U, $F7D8D092, 'sceUtilityUnloadAvModule', hUnloadAvModule);
  H.Register(U, $0D5BC6D2, 'sceUtilityLoadUsbModule', hLoadUsbModule);
  H.Register(U, $F64910F0, 'sceUtilityUnloadUsbModule', hUnloadUsbModule);
end;

initialization
  RegisterPSPService(TPSPUtility);

end.
