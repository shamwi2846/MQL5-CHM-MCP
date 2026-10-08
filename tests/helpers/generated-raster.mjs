// Test-only generator v1. No production parser, filter or pixel helpers are imported.
import { deflateSync } from 'node:zlib';
import { createHash } from 'node:crypto';
export const GENERATOR_VERSION=1;
export const SEED=0x5c018a73;
const passes=[[0,0,8,8],[4,0,8,8],[0,4,4,8],[2,0,4,4],[0,2,2,4],[1,0,2,2],[0,1,1,2]];
export function chunk(name,data=Buffer.alloc(0)) {
 const type=Buffer.isBuffer(name)?name:Buffer.from(name,'ascii');
 const out=Buffer.alloc(12+data.length);out.writeUInt32BE(data.length);type.copy(out,4);data.copy(out,8);
 let crc=0xffffffff;for(const b of out.subarray(4,8+data.length)){crc^=b;for(let bit=0;bit<8;bit++)crc=(crc>>>1)^((crc&1)?0xedb88320:0);}
 out.writeUInt32BE((crc^0xffffffff)>>>0,8+data.length);return out;
}
function predictor(a,b,c){const p=a+b-c,pa=Math.abs(p-a),pb=Math.abs(p-b),pc=Math.abs(p-c);return pa<=pb&&pa<=pc?a:pb<=pc?b:c;}
function rows(width,height,depth,palette,interlace,filter,badPixel=false,badFilter=false) {
 const encoded=[],pixels=[];
 for(let y=0;y<height;y++)pixels.push(Array.from({length:width},(_,x)=>(x+3*y)%palette));
 if(badPixel)pixels[height-1][width-1]=palette;
 for(const [x0,y0,dx,dy] of interlace?passes:[[0,0,1,1]]) {
  const xs=[];for(let x=x0;x<width;x+=dx)xs.push(x);if(!xs.length)continue;
  let previous=Buffer.alloc(Math.ceil(xs.length*depth/8));
  for(let y=y0;y<height;y+=dy){
   const packed=Buffer.alloc(previous.length,255); // Padding bits deliberately remain set.
   xs.forEach((x,j)=>{const shift=8-depth-((j*depth)%8),mask=((1<<depth)-1)<<shift;packed[j*depth>>3]=(packed[j*depth>>3]&~mask)|(pixels[y][x]<<shift);});
   const row=Buffer.alloc(packed.length+1);row[0]=badFilter?5:filter;
   for(let j=0;j<packed.length;j++){const a=j?packed[j-1]:0,b=previous[j],c=j?previous[j-1]:0;const prediction=[0,a,b,Math.floor((a+b)/2),predictor(a,b,c)][filter];row[j+1]=(packed[j]-prediction+256)%256;}
   encoded.push(row);previous=packed;
  }
 }
 return {raw:Buffer.concat(encoded),pixels};
}
export function pngCase(number,seed=SEED){
 let v=(Math.imul(number+1,1664525)+seed)>>>0;v=Math.imul(v^(v>>>16),0x7feb352d)>>>0;v=(v^(v>>>15))>>>0;
 const control=number<40,kind=control?0:(number-40)%16;
 const depth=[1,2,4,8][control?Math.floor(number/10):v%4],width=control?9:1+(v>>>3)%9,height=control?9:1+(v>>>7)%9,interlace=control?number%2:(v>>>12)&1,filter=control?Math.floor(number%10/2):(v>>>15)%5;
 const palette=depth===1?1:1+(v>>>18)%((1<<depth)-1);
 const {raw,pixels}=rows(width,height,depth,palette,interlace,filter,kind===1,kind===2);
 const ihdr=Buffer.alloc(13);ihdr.writeUInt32BE(width);ihdr.writeUInt32BE(height,4);ihdr[8]=depth;ihdr[9]=3;ihdr[12]=interlace;if(kind===13)ihdr[10]=1;
 const colors=Buffer.alloc(palette*3);for(let i=0;i<colors.length;i++)colors[i]=(i*59+v)%256;
 const alpha=Buffer.alloc(1+(v>>>22)%palette,127);
 let parts=[chunk('IHDR',ihdr),chunk('PLTE',colors),chunk('tRNS',kind===6?Buffer.alloc(palette+1):alpha),chunk('IDAT',deflateSync(raw)),chunk('IEND')];
 if(kind===3){const name=Buffer.from('IHDR');name[(v>>>25)%4]|=128;parts[0]=chunk(name,ihdr);if(v&1)parts.splice(3,0,chunk('tRNS',alpha));}
 if(kind===4)parts.splice(3,0,chunk('tRNS',alpha));
 if(kind===5){parts.splice(2,1);parts.splice(3,0,chunk('tRNS',alpha));}
 if(kind===7)[parts[1],parts[2]]=[parts[2],parts[1]];
 if(kind===10){ihdr[8]=8;ihdr[9]=6;ihdr[12]=0;parts=[chunk('IHDR',ihdr),chunk('tRNS',Buffer.alloc(6)),chunk('IDAT',deflateSync(Buffer.alloc(height*(1+4*width)))),chunk('IEND')];}
 if(kind===12)parts.splice(3,0,chunk('IDAT',Buffer.alloc(0)),chunk('tEXt',Buffer.from('key\0value')));
 if(kind===14)parts.splice(3,0,chunk('vpAg',Buffer.from([0,1,2,255])),chunk('tEXt',Buffer.from('key\0value')));
 if(kind===15)parts.splice(3,0,chunk('VPAG',Buffer.from([0,1])));
 let bytes=Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),...parts]);
 if(kind===8)bytes=bytes.subarray(0,bytes.length-1-((v>>>26)%9));
 if(kind===9)bytes.writeUInt32BE(0xffffffff,8);
 if(kind===11)bytes[bytes.length-1]^=1;
 return {category:'PNG',number,seed,generator_version:GENERATOR_VERSION,bytes,valid:[0,14].includes(kind),width,height,depth,filter,interlace,palette,pixels,mutation:kind,input_sha256:createHash('sha256').update(bytes).digest('hex')};
}
export function gifCase(number,seed=SEED){
 const bytes=Buffer.from('47494638396101000100800000000000ffffff2c00000000010001000002024401003b','hex'),kind=number%8;
 if(kind===1)bytes.write('GIF87a',0,'ascii');
 if(kind>=2&&kind<=5){const mask=1+((number+seed)%63);for(let i=0;i<6;i++)if(mask&(1<<i))bytes[i]|=128;}
 if(kind===6)bytes.write('GIF90a',0,'ascii');
 const result=kind===7?bytes.subarray(0,number%6):bytes;
 return {category:'GIF',number,seed,generator_version:GENERATOR_VERSION,bytes:result,valid:kind<2,width:1,height:1,mutation:kind,input_sha256:createHash('sha256').update(result).digest('hex')};
}
