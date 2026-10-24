#!/usr/bin/env python3
"""Original, offline procedural cover art. Requires Pillow and NumPy; no input art."""
from pathlib import Path
import argparse
import math
import random
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

W, H = 1500, 1050
OUT = (1000, 700)

def rgb(c):
    return tuple(int(c[i:i+2], 16) for i in (0, 2, 4))

def mix(a, b, t):
    return tuple(round(x*(1-t)+y*t) for x,y in zip(a,b))

class Canvas:
    def __init__(self, seed, palette, glows=()):
        self.r = random.Random(seed)
        self.n = np.random.default_rng(seed)
        ys = np.linspace(0,1,H)[:,None,None]
        a,b,c = [np.array(rgb(x)) for x in palette]
        top = np.minimum(ys/0.65,1)
        data = np.broadcast_to(a*(1-top)+b*top,(H,W,3)).copy()
        lower=np.clip((ys-0.65)/0.35,0,1)
        data=data*(1-lower)+c*lower
        xx,yy=np.meshgrid(np.linspace(0,1,W),np.linspace(0,1,H))
        for x,y,r,col,strength in glows:
            fall=np.exp(-((xx-x)**2+(yy-y)**2)/(r*r))*strength
            data=data*(1-fall[:,:,None])+np.array(rgb(col))*fall[:,:,None]
        self.im=Image.fromarray(np.uint8(np.clip(data,0,255)))
        self.d=ImageDraw.Draw(self.im)
    def p(self, pts, fill):
        self.d.polygon([(int(x*W),int(y*H)) for x,y in pts], fill=fill)
    def line(self, pts, fill, width=1):
        self.d.line([(int(x*W),int(y*H)) for x,y in pts], fill=fill,width=max(1,round(width*1.5)))
    def ellipse(self, box, fill=None, outline=None, width=1):
        self.d.ellipse(tuple(round(v*(W if i%2==0 else H)) for i,v in enumerate(box)),fill=fill,outline=outline,width=max(1,round(width*1.5)))
    def glow(self, x,y,rx,ry,col,alpha=150):
        layer=Image.new('RGBA',(W,H)); d=ImageDraw.Draw(layer)
        d.ellipse((int((x-rx)*W),int((y-ry)*H),int((x+rx)*W),int((y+ry)*H)),fill=(*rgb(col),alpha))
        layer=layer.filter(ImageFilter.GaussianBlur(rx*W*.45))
        self.im=Image.alpha_composite(self.im.convert('RGBA'),layer).convert('RGB');self.d=ImageDraw.Draw(self.im)
    def stars(self,count=220,limit=.65,col='c6def1'):
        for _ in range(count):
            x,y=self.r.random(),self.r.random()*limit
            r=self.r.choices([.0005,.0009,.0014],[.65,.3,.05])[0]
            color=mix(rgb(col),(30,35,65),self.r.random()*.65)
            self.ellipse((x-r,y-r*W/H,x+r,y+r*W/H),fill=color)
    def mountain(self, base, peaks, dark, light, bottom=1.04):
        pts=[(-.05,base)]+peaks+[(1.05,base),(1.05,bottom),(-.05,bottom)]
        self.p(pts,rgb(dark))
        for i,(x,y) in enumerate(peaks):
            left=peaks[i-1] if i else (-.05,base)
            right=peaks[i+1] if i+1<len(peaks) else (1.05,base)
            foot=(x+(right[0]-x)*.45,bottom)
            self.p([(x,y),left,(x-.04,bottom),foot],rgb(light))
            self.p([(x,y),(x+.015,y+.11),foot],mix(rgb(dark),rgb(light),.38))
    def mist(self,y,col,opacity=35):
        self.glow(.5,y,.65,.025,col,opacity)
    def ocean(self,y,top,bottom,reflection=None):
        # Water picks up the sky but retains subtle depth and hundreds of glints.
        for row in range(int(y*H),H):
            t=(row-y*H)/(H-y*H)
            self.d.line((0,row,W,row),fill=mix(rgb(top),rgb(bottom),t))
        for _ in range(1350):
            yy=self.r.uniform(y,1);t=(yy-y)/(1-y)
            x=self.r.random(); length=self.r.uniform(.001,.025)*(0.2+t)
            color=mix(rgb(top),rgb(bottom),self.r.uniform(.1,.9))
            if reflection and abs(x-reflection[0])<(.025+t*.15)*self.r.uniform(.3,1.5):
                color=mix(color,rgb(reflection[1]),self.r.uniform(.2,.7))
            self.line([(x,yy),(x+length,yy)],color,self.r.choice([.6,.8,1]))
    def tree(self,x,y,size,col):
        self.line([(x,y),(x,y-size)],rgb(col),max(.5,size*16))
        for i in range(5):
            t=i/5;w=size*(.17+.21*t)
            self.p([(x,y-size*(1-t*.7)),(x-w,y-size*(.58-t*.7)),(x+w,y-size*(.58-t*.7))],rgb(col))
    def finish(self,path):
        a=np.asarray(self.im).astype(np.float32)
        noise=self.n.normal(0,1.65,(H,W,1))
        yy,xx=np.mgrid[0:H,0:W]; v=((xx/W-.5)**2+(yy/H-.43)**2)
        a=np.clip(a*(1-.19*v[:,:,None])+noise,0,255).astype(np.uint8)
        Image.fromarray(a).resize(OUT,Image.Resampling.LANCZOS).save(path,optimize=True)

def astral():
    c=Canvas(101,['11122e','646697','24283e'],[(.64,.37,.32,'cd9abd',.65)])
    c.stars(460)
    c.glow(.65,.34,.12,.17,'bca8ec',80)
    c.ellipse((.546,.18,.754,.477),fill=rgb('bdb4d8'))
    # Fine eclipse rings; diagonal orbit gives scale to the mountainous foreground.
    for i in range(4):
        layer=Image.new('RGBA',(W,H));d=ImageDraw.Draw(layer)
        d.ellipse((W*.43,H*.30,W*.86,H*.39),outline=(207,201,242,170-i*30),width=2+i)
        layer=layer.rotate(28,resample=Image.Resampling.BICUBIC,center=(int(.65*W),int(.34*H)))
        c.im=Image.alpha_composite(c.im.convert('RGBA'),layer).convert('RGB');c.d=ImageDraw.Draw(c.im)
    c.mountain(.72,[(.07,.5),(.25,.59),(.43,.4),(.57,.61),(.83,.49),(.95,.58)],'46445e','716b89')
    c.mist(.68,'c6b7d0',100)
    c.ocean(.72,'686b8a','161e34',(.65,'c8c3e3'))
    c.mountain(.94,[(.02,.57),(.12,.67),(.24,.83),(.35,.93)],'141b30','2c324b')
    c.mountain(.99,[(.78,.92),(.91,.7),(1.0,.64)],'10172a','35344b')
    c.line([(.38,.94),(.47,.91),(.6,.92)],rgb('787887'),1)
    return c

def ember():
    c=Canvas(102,['211923','9a5350','d39b69'],[(.61,.53,.4,'f6a057',.65)])
    c.ellipse((.55,.28,.73,.537),fill=rgb('e8b084'))
    c.mountain(.78,[(.02,.64),(.17,.42),(.36,.62),(.59,.28),(.77,.57),(.91,.48)],'5e3b43','945750')
    c.p([(.54,.36),(.59,.28),(.65,.38),(.6,.36),(.57,.38)],rgb('d1a098'))
    for i in range(12):
        c.glow(.59+math.sin(i)*.012,.29-i*.018,.035+i*.004,.025,'4c3840',90)
    c.mountain(.98,[(.02,.61),(.17,.7),(.34,.85),(.47,.8),(.65,.91),(.91,.66),(1,.61)],'282731','48333b')
    path=[(.6,.41),(.57,.57),(.6,.66),(.52,.74),(.58,.84),(.43,1.05)]
    c.line(path,rgb('bf583b'),29);c.line(path,rgb('f58c42'),13);c.line(path,rgb('ffd391'),3)
    c.p([(0,.8),(.23,.89),(.39,1),(0,1)],rgb('1c202b'))
    for _ in range(90):
        x,y=c.r.uniform(.32,.8),c.r.uniform(.4,.98)
        c.ellipse((x,y,x+.001,y+.002),fill=rgb('e8a471'))
    return c

def tide():
    c=Canvas(103,['153e59','7aabae','e6c9a1'],[(.7,.43,.3,'ffe6ad',.9)])
    c.ellipse((.66,.34,.755,.476),fill=rgb('fff1c1'))
    c.mountain(.66,[(.1,.59),(.29,.48),(.46,.6),(.78,.55),(.94,.61)],'61878b','91a3a0')
    c.ocean(.63,'6ba6a5','103d54',(.71,'ffe1ae'))
    c.p([(0,.66),(.16,.59),(.3,.67),(.36,.83),(.26,1),(0,1)],rgb('254451'))
    c.p([(0,.66),(.16,.59),(.3,.67),(.23,.75),(.08,.79),(0,.76)],rgb('627b70'))
    c.p([(.16,.65),(.17,.415),(.192,.415),(.206,.65)],rgb('ddd7bd'))
    c.p([(.17,.415),(.192,.415),(.192,.65),(.183,.65)],rgb('9aa9a1'))
    c.p([(.163,.414),(.199,.414),(.195,.395),(.168,.395)],rgb('293e4a'))
    c.p([(.165,.393),(.197,.393),(.182,.375)],rgb('344956'))
    c.line([(.17,.4),(.193,.4)],rgb('ffe7a6'),3)
    for y in [.72,.77,.85,.94]:
        pts=[(.31+i*.006,y+math.sin(i*.5)*.002) for i in range(42)]
        c.line(pts,rgb('a0c4bd'),1)
    for i in range(7):
        x=.48+i*.045;y=.32+math.sin(i)*.04
        c.line([(x-.008,y),(x,y+.005),(x+.009,y-.003)],rgb('395c67'),1)
    return c

def verdant():
    c=Canvas(104,['122e3e','608c81','d0c599'],[(.53,.35,.3,'e0d6a7',.75)])
    c.mountain(.78,[(.08,.45),(.21,.4),(.32,.56),(.48,.34),(.67,.47),(.84,.36),(.99,.45)],'3b6462','62837a')
    c.mist(.62,'c6d2af',110)
    c.p([(0,.45),(.16,.49),(.3,.63),(.39,.74),(.42,1),(0,1)],rgb('1b4949'))
    c.p([(1,.4),(.82,.5),(.71,.64),(.65,.82),(.61,1),(1,1)],rgb('214c48'))
    c.p([(0,.45),(.16,.49),(.3,.63),(.22,.64),(.11,.56),(0,.55)],rgb('5c8566'))
    c.p([(1,.4),(.82,.5),(.71,.64),(.83,.62),(.95,.48)],rgb('739477'))
    c.p([(.54,.55),(.57,.55),(.565,.82),(.53,.89),(.52,.87)],rgb('adcdc0'))
    c.line([(.553,.56),(.55,.8),(.537,.87)],rgb('dcdfbd'),3)
    c.glow(.54,.85,.09,.025,'d2dec1',100)
    c.p([(.53,.87),(.57,.91),(.45,.98),(.42,1),(.55,1),(.61,.93)],rgb('699e91'))
    for _ in range(165):
        x=c.r.random(); y=c.r.uniform(.54,1)
        if x<.35 or x>.7:c.tree(x,y,c.r.uniform(.025,.13)*(y+.1),c.r.choice(['163d3d','214b43','37644e']))
    # Tiny bridge and solitary explorer establish the monumental scale.
    c.line([(.32,.74),(.44,.77),(.58,.77),(.7,.72)],rgb('acaa7e'),2)
    c.line([(.46,.765),(.46,.749)],rgb('edc58b'),2)
    return c

def neon():
    c=Canvas(105,['10162f','42385a','bf7d83'],[(.7,.49,.27,'e49ca0',.55)])
    c.ellipse((.61,.26,.80,.53),fill=rgb('bdb2bb'))
    for layer in range(3):
        for i in range(45):
            x=i/44+c.r.uniform(-.01,.01);w=c.r.uniform(.012,.048);y=c.r.uniform(.38,.7)+layer*.035
            base=.79+layer*.055
            col=['41435c','2b344e','17283f'][layer]
            c.p([(x,y),(x+w,y),(x+w,base),(x,base)],rgb(col))
            if c.r.random()<.3:c.line([(x+w*.5,y),(x+w*.5,y-.045)],rgb(col),1)
            for wy in np.arange(y+.015,base,.014):
                for wx in np.arange(x+.004,x+w-.003,.008):
                    if c.r.random()<.46:
                        c.line([(wx,wy),(wx+.002,wy)],rgb(c.r.choice(['b59e9c','5f8e9b','c87c97'])),1)
    c.ocean(.85,'313e59','102333',(.7,'db8199'))
    for x,y,w,h,color in [(.14,.47,.018,.15,'df769b'),(.78,.48,.013,.19,'61c3d0'),(.43,.61,.07,.014,'e4aa8b')]:
        c.p([(x,y),(x+w,y),(x+w,y+h),(x,y+h)],rgb(color));c.glow(x+w/2,y+h/2,w*2,h,color,55)
    c.p([(0,.93),(.47,.86),(.55,.86),(1,.96),(1,1),(0,1)],rgb('101f30'))
    for j in range(5):
        c.line([(.5,.88+j*.022),(.5,.892+j*.023)],rgb('d9a582'),2)
    for _ in range(115):
        x,y=c.r.random(),c.r.random();c.line([(x,y),(x-.005,y+.025)],rgb('718099'),.4)
    return c

def orbit():
    c=Canvas(106,['070f22','192c45','415b72'],[(.7,.45,.37,'8b9da2',.35)])
    c.stars(650,1)
    c.glow(.75,.5,.29,.4,'819baf',100)
    c.ellipse((.49,.14,1.03,.912),fill=rgb('9caeb6'))
    # Clipped gas bands on a separate disc, with soft axial shading.
    layer=Image.new('RGB',(W,H));d=ImageDraw.Draw(layer)
    for yy in range(int(.14*H),int(.915*H)):
        t=(yy/H-.14)/.775;v=.5+.25*math.sin(t*63)+.15*math.sin(t*129)
        color=mix(rgb('6b879e'),rgb('cfbfae'),v)
        d.line((0,yy,W,yy),fill=color)
    mask=Image.new('L',(W,H));ImageDraw.Draw(mask).ellipse((.49*W,.14*H,1.03*W,.912*H),fill=255)
    c.im.paste(layer,(0,0),mask);c.d=ImageDraw.Draw(c.im)
    c.ellipse((.69,.14,1.12,.914),fill=rgb('16283e'))
    c.line([(.49,.49),(.5,.4),(.54,.29),(.59,.22)],rgb('d1dce0'),2)
    c.p([(-.05,.79),(.21,.58),(.38,.66),(.08,.92)],rgb('172334'))
    c.p([(.1,.725),(.24,.58),(.3,.61),(.16,.78)],rgb('637f8b'))
    for i in range(7):
        x=.1+i*.021;c.line([(x,.727-i*.02),(x+.055,.759-i*.02)],rgb('a5b4b5'),1)
    c.line([(.245,.65),(.39,.48)],rgb('a5bac4'),8)
    c.ellipse((.329,.41,.45,.583),outline=rgb('9aafb8'),width=6)
    c.ellipse((.346,.434,.433,.558),outline=rgb('314459'),width=2)
    for a in range(0,360,45):
        r=math.radians(a);c.line([(.39,.496),(.39+.057*math.cos(r),.496+.081*math.sin(r))],rgb('8b9da6'),1)
    c.glow(.34,.6,.018,.018,'9be2ed',140)
    return c

def dune():
    c=Canvas(107,['352c3c','bc7863','edc693'],[(.59,.42,.36,'f7d19b',.8)])
    c.ellipse((.49,.2,.69,.486),fill=rgb('eac6a3'))
    c.ellipse((.5,.2,.683,.461),fill=rgb('493847'))
    c.glow(.59,.35,.13,.18,'eab896',35)
    c.mountain(.68,[(.03,.59),(.16,.54),(.28,.61),(.49,.52),(.71,.6),(.86,.51)],'aa7563','c38d70')
    # Large sweeping curved dunes, subtly faceted and finely lined.
    for k,(y,color) in enumerate([(.68,'d09a73'),(.77,'b67960'),(.88,'8c5551'),(1.02,'573c43')]):
        points=[(x/100,y+.065*math.sin(x/100*5+k*1.7)) for x in range(-5,106)]
        c.p(points+[(1.05,1.05),(-.05,1.05)],rgb(color))
        for j in range(12):
            pts=[(x/100,yy+j*.006) for (x,yy) in [(p[0]*100,p[1]) for p in points]]
            c.line(pts,mix(rgb(color),rgb('efc69b'),.11),.5)
    c.p([(.73,.61),(.741,.40),(.753,.40),(.768,.62)],rgb('58434a'))
    c.p([(.741,.40),(.747,.36),(.753,.40)],rgb('bb9a83'))
    for i in range(13):
        x=.4+i*.009;y=.92-i*.01
        c.ellipse((x,y,x+.0018,y+.0017),fill=rgb('63434a'))
    c.line([(.49,.824),(.49,.795)],rgb('332d39'),2)
    c.p([(.488,.8),(.482,.821),(.501,.82)],rgb('3c303b'))
    return c

def frost():
    c=Canvas(108,['102b42','346177','9dc2c7'],[(.68,.42,.25,'9fe5d7',.35)])
    c.stars(270,.6)
    for k in range(4):
        layer=Image.new('RGBA',(W,H));d=ImageDraw.Draw(layer)
        pts=[]
        for i in range(101):
            x=i/100;y=.19+.08*math.sin(x*6+k*.4)
            pts.append((int(x*W),int(y*H)))
        d.line(pts,fill=(77,215,180,80-k*12),width=15+k*15)
        layer=layer.filter(ImageFilter.GaussianBlur(16+k*7));c.im=Image.alpha_composite(c.im.convert('RGBA'),layer).convert('RGB');c.d=ImageDraw.Draw(c.im)
    c.mountain(.8,[(.02,.61),(.18,.42),(.34,.62),(.56,.30),(.75,.55),(.88,.43),(1,.57)],'547c90','a1c3ca')
    for x,y in [(.18,.42),(.56,.3),(.88,.43)]:
        c.p([(x,y),(x-.06,y+.11),(x-.012,y+.085),(x+.02,y+.12),(x+.055,y+.10)],rgb('c8dddd'))
    c.mist(.73,'b8d8dc',80)
    c.ocean(.77,'588d9e','193c57',(.61,'b9ddd9'))
    c.p([(0,.88),(.14,.83),(.29,.89),(.4,1),(0,1)],rgb('8fb5c4'))
    c.p([(0,.94),(.2,.92),(.29,.89),(.4,1),(0,1)],rgb('416b87'))
    c.p([(.77,1),(.85,.87),(.91,.9),(1,.81),(1,1)],rgb('9fc4ce'))
    c.line([(.3,1),(.36,.93),(.52,.9),(.58,.83)],rgb('bdd5d9'),1)
    return c

def echo():
    c=Canvas(109,['252443','826e8f','d1a2ac'],[(.5,.4,.35,'f0cbcb',.6)])
    c.stars(170,.5,'dcc5d6')
    c.ocean(.69,'8b7b99','24273f',(.51,'e7bdc8'))
    # A monumental incomplete gate, reflected in quiet water.
    c.ellipse((.365,.20,.635,.67),outline=rgb('b7a4b8'),width=24)
    c.ellipse((.382,.225,.618,.655),outline=rgb('e4c7d0'),width=2)
    c.p([(.54,.18),(.66,.21),(.66,.35),(.585,.315)],rgb('8a7896'))
    c.p([(.34,.57),(.4,.57),(.42,.7),(.32,.7)],rgb('4b4963'))
    c.p([(.6,.57),(.66,.57),(.68,.7),(.58,.7)],rgb('645874'))
    for x,y,s in [(.15,.53,.11),(.81,.44,.13),(.25,.28,.035),(.73,.23,.025)]:
        c.p([(x-s,y),(x+s,y-.02),(x+s*.55,y+.03),(x,y+s*.8)],rgb('45445e'))
        c.p([(x-s,y),(x,y-.035),(x+s,y-.02),(x+s*.5,y+.008)],rgb('9b8b9e'))
        c.line([(x,y+.04),(x-.01,y+.17)],rgb('8f829b'),1)
    c.p([(0,.97),(.22,.88),(.44,.9),(.63,.85),(.8,.9),(1,.86),(1,1),(0,1)],rgb('272a43'))
    for i in range(22):
        y=.7+i*.009;half=.13*(1-i/35)
        c.line([(.5-half,y),(.5+half,y)],mix(rgb('b49ab4'),rgb('4b4867'),i/25),1)
    return c

def lumen():
    c=Canvas(110,['38435a','b79788','f6d19c'],[(.53,.4,.32,'fff0bd',.93)])
    c.ellipse((.43,.19,.63,.476),fill=rgb('fff0c8'))
    for r in [.15,.18,.22]:
        c.ellipse((.53-r,.333-r*W/H,.53+r,.333+r*W/H),outline=rgb('d1b49a'),width=.6)
    c.mountain(.74,[(.0,.55),(.15,.42),(.31,.61),(.48,.55),(.65,.60),(.84,.40),(1,.54)],'8a7d81','b29d96')
    c.mist(.69,'f3d5ac',120)
    c.mountain(.94,[(.02,.64),(.15,.7),(.28,.82),(.45,.84),(.67,.78),(.91,.61)],'555b64','807b7b')
    c.p([(.32,1),(.44,.84),(.53,.79),(.59,.79),(.48,.89),(.46,1)],rgb('b1a495'))
    # Sunlit stepped sanctuary, visible at thumbnail scale without lettering.
    for i in range(4):
        x=.49+i*.008;y=.78-i*.018;w=.17-i*.016
        c.p([(x,y),(x+w,y),(x+w,y+.018),(x,y+.018)],rgb('d5bd98'))
    for i in range(5):
        x=.523+i*.024;c.p([(x,.64),(x+.012,.64),(x+.012,.728),(x,.728)],rgb('e8cc9e'))
        c.p([(x+.008,.64),(x+.012,.64),(x+.012,.728),(x+.008,.728)],rgb('a7937d'))
    c.p([(.51,.64),(.578,.594),(.645,.64)],rgb('f3d6a7'))
    c.line([(.51,.646),(.645,.646)],rgb('ab967d'),2)
    for _ in range(85):
        x=c.r.random();y=c.r.uniform(.7,1)
        if x<.35 or x>.72:c.tree(x,y,c.r.uniform(.02,.08),'424d55')
    c.glow(.57,.62,.08,.10,'ffdda0',45)
    return c

SCENES = {f.__name__: f for f in (astral,ember,tide,verdant,neon,orbit,dune,frost,echo,lumen)}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=Path(__file__).resolve().parents[1]/'assets')
    parser.add_argument('--only',choices=SCENES)
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    for name,fn in SCENES.items():
        if args.only and name != args.only:continue
        path=args.output/(name+'.png');fn().finish(path)
        print(f'{path.name}: 1000 x 700 RGB PNG')

if __name__=='__main__':main()
