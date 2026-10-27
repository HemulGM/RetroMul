unit FMX.SVG.Cache;

interface

uses
  System.Math, FMX.Graphics;

type
  TSvgBitmapCache = class
  private
    FBitmap: TBitmap;
    FDirty: Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Invalidate;
    procedure EnsureSize(const Width, Height, Scale: Single);

    property Bitmap: TBitmap read FBitmap;
    property Dirty: Boolean read FDirty write FDirty;
  end;

implementation

constructor TSvgBitmapCache.Create;
begin
  inherited;
  FBitmap := TBitmap.Create(1, 1);
  FDirty := True;
end;

destructor TSvgBitmapCache.Destroy;
begin
  FBitmap.Free;
  inherited;
end;

procedure TSvgBitmapCache.Invalidate;
begin
  FDirty := True;
end;

procedure TSvgBitmapCache.EnsureSize(const Width, Height, Scale: Single);
begin
  var BitmapWidth := Max(1, Ceil(Width * Scale));
  var BitmapHeight := Max(1, Ceil(Height * Scale));
  if (FBitmap.Width <> BitmapWidth) or (FBitmap.Height <> BitmapHeight) then
  begin
    FBitmap.SetSize(BitmapWidth, BitmapHeight);
    FDirty := True;
  end;
end;

end.

