unit RM.VMUOverlay;

// The Visual Memory display of a Dreamcast controller over a corner of the
// game picture. The core supplies the LCD separately from the frame, so
// screenshots and frame hashes contain only the game picture.

interface

uses
  System.SysUtils, System.Types, System.UITypes, FMX.Types, FMX.Controls,
  FMX.Objects, FMX.Graphics, Core.Emulation;

type
  TVMUOverlay = class
  private
    FHost: TControl;
    FImage: TImage;
    FCore: Pointer;
    FShown: Boolean;
    procedure Place(const Corner: string);
  public
    // The image belongs to Host.
    constructor Create(Host: TControl);
    // Call on the frontend thread after each frame. Hidden for other cores,
    // when switched off and until the game first draws on the display.
    procedure Update(const Core: IEmulationCore);
    procedure Hide;
  end;

implementation

uses
  System.Math, Core.Adapter.DC;

const
  VMUWidth = 48;
  VMUHeight = 32;
  VMUBackground: TAlphaColor = $FF9EBBA9;
  VMUPixel: TAlphaColor = $FF1B2A44;

constructor TVMUOverlay.Create(Host: TControl);
begin
  inherited Create;
  FHost := Host;
end;

procedure TVMUOverlay.Hide;
begin
  FCore := nil;
  FShown := False;
  if FImage <> nil then
    FImage.Visible := False;
end;

procedure TVMUOverlay.Place(const Corner: string);
const
  Margin = 12;
begin
  var Width := EnsureRange(FHost.Width * 0.2, VMUWidth * 2.0, VMUWidth * 6.0);
  var Height := Width * VMUHeight / VMUWidth;
  var X := Single(Margin);
  var Y := Single(Margin);
  if Corner.EndsWith('right') then
    X := FHost.Width - Width - Margin;
  if Corner.StartsWith('bottom') then
    Y := FHost.Height - Height - Margin;
  FImage.SetBounds(X, Y, Width, Height);
end;

procedure TVMUOverlay.Update(const Core: IEmulationCore);
begin
  var Screen: IDCVMUScreen;
  if (Core = nil) or not Supports(Core, IDCVMUScreen, Screen) then
  begin
    Hide;
    Exit;
  end;
  if FCore <> Pointer(Core) then
  begin
    Hide;
    FCore := Pointer(Core);
  end;
  var Corner := Screen.VMUScreenCorner;
  var Pixels: TBytes;
  if Screen.TakeVMUScreen(Pixels) and (Length(Pixels) = VMUWidth * VMUHeight) then
  begin
    if FImage = nil then
    begin
      FImage := TImage.Create(FHost);
      FImage.HitTest := False;
      FImage.WrapMode := TImageWrapMode.Stretch;
      FImage.DisableInterpolation := True;
      FImage.Opacity := 0.9;
      FImage.Bitmap.SetSize(VMUWidth, VMUHeight);
      FImage.Parent := FHost;
    end;
    var Data: TBitmapData;
    if FImage.Bitmap.Map(TMapAccess.Write, Data) then
    try
      for var Y := 0 to VMUHeight - 1 do
        for var X := 0 to VMUWidth - 1 do
          if Pixels[Y * VMUWidth + X] <> 0 then
            Data.SetPixel(X, Y, VMUPixel)
          else
            Data.SetPixel(X, Y, VMUBackground);
    finally
      FImage.Bitmap.Unmap(Data);
    end;
    FShown := True;
  end;
  if FImage = nil then
    Exit;
  FImage.Visible := FShown and (Corner <> 'off');
  if FImage.Visible then
  begin
    Place(Corner);
    FImage.BringToFront;
  end;
end;

end.

