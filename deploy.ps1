# dogFooding-app 部署脚本
$server = "49.235.161.106"
$sshUser = "root"
$remoteDir = "/opt/apps/dogFooding-app"
$localJar = "target/dogFooding.jar"
$localDockerfile = "dogFooding_Dockerfile"
$imageName = "dogFooding-app:1.0.0"
$containerName = "dogFooding-app"
$port = "10011"

Write-Host "=== 开始部署 dogFooding-app ===" -ForegroundColor Cyan

# 1. 检查本地文件是否存在
Write-Host "`n[1/8] 检查本地文件..." -ForegroundColor Yellow
if (-not (Test-Path $localJar)) {
    Write-Host "错误: $localJar 不存在！" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $localDockerfile)) {
    Write-Host "错误: $localDockerfile 不存在！" -ForegroundColor Red
    exit 1
}
Write-Host "本地文件检查完成" -ForegroundColor Green

# 2. 服务器连接测试
Write-Host "`n[2/8] 测试服务器连接..." -ForegroundColor Yellow
$connectTest = ssh -o BatchMode=yes -o ConnectTimeout=10 ${sshUser}@${server} "echo '连接成功'" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "错误: 无法连接到服务器 $server，请检查SSH密钥配置" -ForegroundColor Red
    exit 1
}
Write-Host "服务器连接成功" -ForegroundColor Green

# 3. 服务器前置检查
Write-Host "`n[3/8] 服务器前置检查..." -ForegroundColor Yellow

# 检查Docker是否运行
$dockerStatus = ssh ${sshUser}@${server} "systemctl is-active docker 2>/dev/null || echo 'not-running'"
if ($dockerStatus -ne "active") {
    Write-Host "错误: Docker 未在服务器上运行！状态: $dockerStatus" -ForegroundColor Red
    exit 1
}
Write-Host "Docker 运行状态: 正常" -ForegroundColor Green

# 创建/检查目录权限
ssh ${sshUser}@${server} "mkdir -p $remoteDir && chown -R root:root $remoteDir && chmod 755 $remoteDir"
Write-Host "目录权限检查/修复完成" -ForegroundColor Green

# 检查端口10011占用
$portInfo = ssh ${sshUser}@${server} "lsof -i :$port -t 2>/dev/null | head -1"
if ($portInfo) {
    # 检查是否是容器进程
    $containerCheck = ssh ${sshUser}@${server} "docker ps -q --filter ""publish=$port"" 2>/dev/null"
    if ($containerCheck) {
        Write-Host "端口 $port 被容器占用，准备停止并删除容器..." -ForegroundColor Yellow
        ssh ${sshUser}@${server} "docker stop $containerName 2>/dev/null; docker rm $containerName 2>/dev/null"
        Write-Host "容器已停止并删除" -ForegroundColor Green
    } else {
        Write-Host "错误: 端口 $port 被非容器进程占用！PID: $portInfo" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "端口 $port 检查: 可用" -ForegroundColor Green
}

# 检查并对比服务器上的Dockerfile
$remoteDockerfileExists = ssh ${sshUser}@${server} "test -f $remoteDir/dogFooding_Dockerfile && echo 'exists' || echo 'not-exists'"
if ($remoteDockerfileExists -eq "exists") {
    $localContent = Get-Content $localDockerfile -Raw
    $remoteContent = ssh ${sshUser}@${server} "cat $remoteDir/dogFooding_Dockerfile"
    if ($localContent.Trim() -ne $remoteContent.Trim()) {
        Write-Host "发现服务器上的Dockerfile内容不一致，将覆盖..." -ForegroundColor Yellow
        Write-Host "=== 日志: Dockerfile内容不一致，执行覆盖 ===" -ForegroundColor Magenta
    } else {
        Write-Host "服务器上的Dockerfile内容一致" -ForegroundColor Green
    }
}

# 4. 清理旧文件并上传
Write-Host "`n[4/8] 清理旧文件并上传..." -ForegroundColor Yellow
ssh ${sshUser}@${server} "rm -rf $remoteDir/dogFooding.jar $remoteDir/dogFooding_Dockerfile"
Write-Host "旧文件已清理" -ForegroundColor Green

# 上传文件
scp $localJar ${sshUser}@${server}:$remoteDir/
if ($LASTEXITCODE -ne 0) {
    Write-Host "错误: 上传 jar 文件失败！" -ForegroundColor Red
    exit 1
}
scp $localDockerfile ${sshUser}@${server}:$remoteDir/
if ($LASTEXITCODE -ne 0) {
    Write-Host "错误: 上传 Dockerfile 文件失败！" -ForegroundColor Red
    exit 1
}
Write-Host "文件上传完成" -ForegroundColor Green

# 5. 清理旧容器和镜像
Write-Host "`n[5/8] 清理旧容器和镜像..." -ForegroundColor Yellow
ssh ${sshUser}@${server} "docker stop $containerName 2>/dev/null; docker rm $containerName 2>/dev/null; docker rmi $imageName 2>/dev/null; echo '清理完成'"
Write-Host "旧容器和镜像清理尝试完成" -ForegroundColor Green

# 6. 构建镜像
Write-Host "`n[6/8] 构建Docker镜像..." -ForegroundColor Yellow
ssh ${sshUser}@${server} "cd $remoteDir; docker build -f dogFooding_Dockerfile -t $imageName ."
if ($LASTEXITCODE -ne 0) {
    Write-Host "错误: Docker镜像构建失败！" -ForegroundColor Red
    exit 1
}
Write-Host "镜像构建成功" -ForegroundColor Green

# 7. 启动容器
Write-Host "`n[7/8] 启动容器..." -ForegroundColor Yellow
$portMapping = "${port}:${port}"
ssh ${sshUser}@${server} "docker run -d --name $containerName --restart=always --memory=512m --cpus=0.5 -p $portMapping $imageName"
if ($LASTEXITCODE -ne 0) {
    Write-Host "错误: 容器启动失败！" -ForegroundColor Red
    exit 1
}
Write-Host "容器启动命令已执行" -ForegroundColor Green

# 8. 验证服务
Write-Host "`n[8/8] 验证服务状态..." -ForegroundColor Yellow
Write-Host "等待15秒让服务启动..." -ForegroundColor Cyan
Start-Sleep -Seconds 15

$response = ssh ${sshUser}@${server} "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$port 2>/dev/null || echo '000'"
if ($response -eq "200") {
    Write-Host "`n=== 部署成功 ===" -ForegroundColor Green
    Write-Host "访问地址: http://${server}:${port}" -ForegroundColor Cyan
    Write-Host "状态码: $response" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n=== 部署失败 ===" -ForegroundColor Red
    Write-Host "状态码: $response" -ForegroundColor Red
    Write-Host "`n容器日志:" -ForegroundColor Yellow
    ssh ${sshUser}@${server} "docker logs --tail 50 $containerName 2>&1"
    exit 1
}
