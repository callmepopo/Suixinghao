class VoicePCM extends AudioWorkletProcessor {
  constructor(){
    super();
    this.q=[];          // 下行播放队列（模块 → 浏览器）
    this.h=0;           // 读位置
    this.pos=0;         // 重采样插值相位
    this.phase=0;       // 48k → 8k 抽取相位
    this.sum=0;         // 抽取累加
    this.n=0;           // 抽取计数
    this.frame=[];      // 待发送的 160 个 8k 样本
    this.muted=false;
    this.inSamples=0;   // 收到的输入样本数（用于诊断）
    this.emitted=0;     // 已产出的 8k 样本数
    this.frames=0;      // 已 POST 的帧数
    this.FRAME=160;
    this.port.onmessage=e=>{
      if(e.data&&e.data.mute!==undefined){this.muted=e.data.mute;return}
      if(e.data&&e.data.diag){this.report();return}
      let v=new DataView(e.data);
      for(let i=0;i<v.byteLength;i+=2)this.q.push(v.getInt16(i,true)/32768);
      // 下行积压超过 0.5 秒时只保留最近 100ms，避免延迟越滚越大
      if(this.q.length-this.h>4000){this.h=this.q.length-800;this.pos=0}
    };
  }
  report(){
    this.port.postMessage({diag:{inSamples:this.inSamples,emitted:this.emitted,frames:this.frames,queue:this.q.length-this.h,muted:this.muted}});
  }
  process(inputs,outputs){
    const mic=inputs[0]&&inputs[0][0];
    const out=outputs[0]&&outputs[0][0];
    const step=8000/sampleRate;          // 重采样插值步长
    const decim=Math.max(1,Math.round(sampleRate/8000)); // 48k→8k 每 6 个输入样本产出 1 个
    for(let i=0;i<out.length;i++){
      if(mic&&mic.length){
        this.inSamples++;
        this.sum+=this.muted?0:mic[i];
        this.n++;
      }
      this.phase+=1;
      if(this.phase>=decim){
        this.phase-=decim;
        const s=this.n?this.sum/this.n:0;
        this.frame.push(Math.round(Math.max(-1,Math.min(1,s))*32767));
        this.emitted++;
        this.sum=0;this.n=0;
        if(this.frame.length>=this.FRAME){
          const b=new ArrayBuffer(this.FRAME*2),v=new DataView(b);
          for(let j=0;j<this.FRAME;j++)v.setInt16(j*2,this.frame[j],true);
          this.port.postMessage(b,[b]);
          this.frames++;
          this.frame=[];
        }
      }
      if(this.h+1<this.q.length){
        out[i]=this.q[this.h]*(1-this.pos)+this.q[this.h+1]*this.pos;
        this.pos+=step;
        while(this.pos>=1){this.pos-=1;this.h++}
      }else{
        out[i]=0;this.pos=0;
      }
    }
    if(this.h>8000){this.q=this.q.slice(this.h);this.h=0}
    return true;
  }
}
registerProcessor('voice-pcm',VoicePCM)
