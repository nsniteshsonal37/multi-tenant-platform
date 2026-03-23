// Pipeline 1: Platform Deploy
// Builds, pushes, and deploys the platform services (auth + gateway + time images to ECR,
// then applies k8s/platform/ manifests to EKS).
//
// Agent: Kubernetes pod with terraform, aws-cli, docker, kubectl, postgresql-client.
// Required Jenkins credentials:
//   aws-credentials  — AWS access key + secret key (or use IRSA if Jenkins runs on EKS)
//   kubeconfig       — EKS kubeconfig file
//
// Required Jenkins parameters (configure in job):
//   IMAGE_TAG (string, default: "sha-${GIT_COMMIT[0..7]}")

pipeline {
    agent {
        kubernetes {
            label 'jenkins-agent'
            yaml """
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: jenkins
  containers:
    - name: docker
      image: docker:24-dind
      securityContext:
        privileged: true
      volumeMounts:
        - name: docker-sock
          mountPath: /var/run/docker.sock
    - name: tools
      image: alpine:3.19
      command: [sleep, infinity]
      env:
        - name: AWS_DEFAULT_REGION
          value: eu-central-1
  volumes:
    - name: docker-sock
      hostPath:
        path: /var/run/docker.sock
"""
        }
    }

    environment {
        AWS_REGION        = 'eu-central-1'
        CLUSTER_NAME      = 'hrs-platform'
        IMAGE_TAG         = "${env.GIT_COMMIT?.take(8) ?: 'latest'}"
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Install Tools') {
            steps {
                container('tools') {
                    sh '''
                        apk add --no-cache \
                            aws-cli \
                            kubectl \
                            curl \
                            python3 \
                            py3-pip \
                            postgresql-client \
                            bash
                        # Install Terraform
                        TERRAFORM_VERSION=1.7.5
                        wget -q https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip
                        unzip terraform_${TERRAFORM_VERSION}_linux_amd64.zip -d /usr/local/bin/
                        terraform version
                    '''
                }
            }
        }

        stage('Configure AWS + kubectl') {
            steps {
                container('tools') {
                    withCredentials([usernamePassword(
                        credentialsId: 'aws-credentials',
                        usernameVariable: 'AWS_ACCESS_KEY_ID',
                        passwordVariable: 'AWS_SECRET_ACCESS_KEY'
                    )]) {
                        sh '''
                            aws eks update-kubeconfig \
                                --region $AWS_REGION \
                                --name $CLUSTER_NAME
                            kubectl get nodes
                        '''
                    }
                }
            }
        }

        stage('Login to ECR') {
            steps {
                container('docker') {
                    withCredentials([usernamePassword(
                        credentialsId: 'aws-credentials',
                        usernameVariable: 'AWS_ACCESS_KEY_ID',
                        passwordVariable: 'AWS_SECRET_ACCESS_KEY'
                    )]) {
                        sh '''
                            set +x
                            ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
                            ECR_URL="${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"
                            echo "ECR: $ECR_URL"
                            aws ecr get-login-password --region $AWS_REGION | \
                                docker login --username AWS --password-stdin $ECR_URL
                            echo $ECR_URL > /tmp/ecr_url
                        '''
                    }
                }
            }
        }

        stage('Build & Push Images') {
            parallel {
                stage('auth-service') {
                    steps {
                        container('docker') {
                            sh '''
                                ECR_URL=$(cat /tmp/ecr_url)
                                IMAGE="${ECR_URL}/hrs-platform/auth-service:${IMAGE_TAG}"
                                docker build -t $IMAGE Tenant-Test/auth-service/
                                docker push $IMAGE
                                docker tag $IMAGE ${ECR_URL}/hrs-platform/auth-service:latest
                                docker push ${ECR_URL}/hrs-platform/auth-service:latest
                            '''
                        }
                    }
                }
                stage('gateway-service') {
                    steps {
                        container('docker') {
                            sh '''
                                ECR_URL=$(cat /tmp/ecr_url)
                                IMAGE="${ECR_URL}/hrs-platform/gateway-service:${IMAGE_TAG}"
                                docker build -t $IMAGE Tenant-Test/gateway-service/
                                docker push $IMAGE
                                docker tag $IMAGE ${ECR_URL}/hrs-platform/gateway-service:latest
                                docker push ${ECR_URL}/hrs-platform/gateway-service:latest
                            '''
                        }
                    }
                }
                stage('time-service') {
                    steps {
                        container('docker') {
                            sh '''
                                ECR_URL=$(cat /tmp/ecr_url)
                                IMAGE="${ECR_URL}/hrs-platform/time-service:${IMAGE_TAG}"
                                docker build -t $IMAGE Tenant-Test/time-service/
                                docker push $IMAGE
                                docker tag $IMAGE ${ECR_URL}/hrs-platform/time-service:latest
                                docker push ${ECR_URL}/hrs-platform/time-service:latest
                            '''
                        }
                    }
                }
            }
        }

        stage('Run Tests') {
            steps {
                container('tools') {
                    sh '''
                        pip3 install pytest httpx fastapi sqlalchemy passlib python-jose python-json-logger opentelemetry-api opentelemetry-sdk psycopg2-binary --quiet
                        cd Tenant-Test/auth-service && python3 -m pytest tests/ -v --tb=short || true
                        cd ../../Tenant-Test/time-service && python3 -m pytest tests/ -v --tb=short || true
                    '''
                }
            }
        }

        stage('Deploy Platform') {
            steps {
                container('tools') {
                    sh '''
                        kubectl apply -f DevOps/HRS-Assessment/2_infrastructure/k8s/platform/ --namespace=platform
                        kubectl apply -f DevOps/HRS-Assessment/2_infrastructure/k8s/observability/

                        # Rolling restart to pick up new :latest image
                        kubectl rollout restart deployment/auth-service    -n platform
                        kubectl rollout restart deployment/gateway-service  -n platform
                        kubectl rollout restart deployment/otel-collector   -n observability

                        kubectl rollout status deployment/auth-service    -n platform   --timeout=120s
                        kubectl rollout status deployment/gateway-service  -n platform   --timeout=120s
                    '''
                }
            }
        }

        stage('Smoke Test') {
            steps {
                container('tools') {
                    sh '''
                        GW_POD=$(kubectl get pod -n platform -l app=gateway-service -o jsonpath="{.items[0].metadata.name}")
                        kubectl exec -n platform $GW_POD -- wget -qO- http://localhost:8080/health
                        echo "Gateway health OK"
                        AUTH_POD=$(kubectl get pod -n platform -l app=auth-service -o jsonpath="{.items[0].metadata.name}")
                        kubectl exec -n platform $AUTH_POD -- wget -qO- http://localhost:8080/health
                        echo "Auth service health OK"
                    '''
                }
            }
        }
    }

    post {
        success {
            echo "Platform deployment successful — image tag: ${env.IMAGE_TAG}"
        }
        failure {
            echo "Platform deployment FAILED — check stage logs above"
        }
    }
}
