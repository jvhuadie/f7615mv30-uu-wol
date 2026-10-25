package local.ont.uuwol;
import java.io.*;import java.security.*;import java.util.*;import java.util.concurrent.TimeUnit;import org.osgi.framework.*;
public final class Activator implements BundleActivator {
 private volatile boolean stopping;private volatile Process child;private Thread worker;private File data,runtime;private Properties hashes;
 public void start(BundleContext c)throws Exception{
  stopping=false;data=c.getDataFile("");if(!data.isDirectory()&&!data.mkdirs())throw new IOException("data directory");
  runtime=new File(data,"temp");if(!runtime.isDirectory())throw new IOException("factory temporary directory missing");
  hashes=new Properties();try(InputStream in=getClass().getResourceAsStream("/manifest.properties")){hashes.load(in);}
  for(String n:new String[]{"uuplugin","xuplugin-guardian","pid-prepare"})prepare(n);
  File conf=new File(data,"uu.conf");if(!conf.exists())try(Writer w=new FileWriter(conf)){w.write("log_level=info\nversion=v14.10.6\nlan_ifname=br0\nsn_no_mac_prefix=1\n");}
  if(!new File(data,"enabled").isFile()){state("STAGED",0,0);return;}
  worker=new Thread(new Runnable(){public void run(){supervise();}},"f7005-uu-service");worker.setDaemon(true);worker.start();
 }
 static String sha(File f)throws Exception{MessageDigest md=MessageDigest.getInstance("SHA-256");try(InputStream in=new FileInputStream(f)){byte[] b=new byte[8192];int n;while((n=in.read(b))!=-1)md.update(b,0,n);}StringBuilder s=new StringBuilder();for(byte b:md.digest())s.append(String.format("%02x",b&255));return s.toString();}
 private void verify(String n)throws Exception{if(!sha(new File(data,n)).equals(hashes.getProperty(n)))throw new IOException("HASH_MISMATCH:"+n);}
 private void prepare(String n)throws Exception{File f=new File(data,n);if(!f.exists()){try(InputStream in=getClass().getResourceAsStream("/payload/"+n);OutputStream out=new FileOutputStream(f)){byte[] b=new byte[8192];int k;while((k=in.read(b))!=-1)out.write(b,0,k);}if(!f.setExecutable(true,true))throw new IOException("chmod:"+n);}verify(n);}
 private synchronized void state(String s,int attempts,int code){try{Properties p=new Properties();p.setProperty("version","0.1.0-rc1");p.setProperty("state",s);p.setProperty("attempts",String.valueOf(attempts));p.setProperty("exit",String.valueOf(code));p.setProperty("reboot_acceptance","PENDING");try(OutputStream o=new FileOutputStream(new File(runtime,"status.properties"))){p.store(o,"UU F7005MV3 candidate");}}catch(Exception ignored){}}
 private void supervise(){int attempts=0;long window=System.nanoTime();try{
  while(!stopping){if(System.nanoTime()-window>TimeUnit.HOURS.toNanos(1)){window=System.nanoTime();attempts=0;}if(++attempts>6){state("RETRY_LIMIT",attempts,0);return;}
   verify("pid-prepare");verify("uuplugin");verify("xuplugin-guardian");
   Process pid=new ProcessBuilder(new File(data,"pid-prepare").getAbsolutePath()).directory(data).start();if(!pid.waitFor(3,TimeUnit.SECONDS)){pid.destroyForcibly();throw new IOException("PID_HELPER_TIMEOUT");}if(pid.exitValue()!=0){state("PID_PREPARE_FAILED",attempts,pid.exitValue());return;}
   long inode=0;try(InputStream in=pid.getInputStream()){for(int i=0;i<8;i++){int b=in.read();if(b<0)throw new IOException("PID_IDENTITY_MISSING");inode|=((long)b)<<(8*i);}}try(Writer w=new FileWriter(new File(runtime,"pid.inode"))){w.write(Long.toString(inode));}
   if(new File(data,"pid-only").isFile()){state("PID_READY",attempts,0);return;}
   if(stopping)return;
   child=new ProcessBuilder(new File(data,"uuplugin").getAbsolutePath(),"./uu.conf").directory(data).redirectErrorStream(true).start();state("RUNNING",attempts,0);
   try(InputStream in=child.getInputStream()){
    byte[] b=new byte[1024];long last=System.nanoTime();while(!stopping&&child.isAlive()){int available=in.available();if(available>0){int n=in.read(b,0,Math.min(available,b.length));if(n>0)append(b,n);}if(System.nanoTime()-last>TimeUnit.SECONDS.toNanos(15)){state("RUNNING",attempts,0);last=System.nanoTime();}Thread.sleep(100);}
   }
   if(stopping)break;int code=child.exitValue();state("RETRY_WAIT",attempts,code);Thread.sleep(10000);
  }
 }catch(InterruptedException e){Thread.currentThread().interrupt();}catch(Exception e){state("FAILED:"+e.getClass().getSimpleName()+":"+e.getMessage(),attempts,-1);}finally{terminate();if(stopping)state("STOPPED",attempts,0);}}
 private synchronized void append(byte[] b,int n)throws IOException{File f=new File(runtime,"service.log");if(f.length()+n>65536){File prev=new File(runtime,"service.previous");if(prev.exists()&&!prev.delete())throw new IOException("log rotation");if(f.exists()&&!f.renameTo(prev))throw new IOException("log rename");}try(OutputStream out=new FileOutputStream(f,true)){out.write(b,0,n);}}
 private void terminate(){Process p=child;if(p!=null&&p.isAlive()){p.destroy();try{if(!p.waitFor(2,TimeUnit.SECONDS)){p.destroyForcibly();p.waitFor(1,TimeUnit.SECONDS);}}catch(InterruptedException e){Thread.currentThread().interrupt();}}}
 public void stop(BundleContext c){stopping=true;terminate();if(worker!=null){worker.interrupt();try{worker.join(4000);}catch(InterruptedException e){Thread.currentThread().interrupt();}}state("STOPPED",0,0);}
}
