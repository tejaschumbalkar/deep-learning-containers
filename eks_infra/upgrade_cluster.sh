#!/bin/bash
#/ Usage: 
#/ export AWS_REGION=<AWS-Region>
#/ export EC2_KEY_PAIR_NAME=<EC2-Key-Pair-Name>
#/ export EKS_CLUSTER_MANAGER_ROLE=<ARN-of-IAM-role>
#/ ./upgrade.sh eks_cluster_name eks_version cluster_autoscalar_image_version
set -ex

# Function to update kubeconfig at ~/.kube/config
function update_kubeconfig(){

    eksctl utils write-kubeconfig \
    --cluster ${1} \
    --authenticator-role-arn ${2} \
    --region ${3}

    kubectl config get-contexts
    cat /root/.kube/config
}

# Function to upgrade eks control plane
function upgrade_eks_control_plane(){

    eksctl upgrade cluster \
    --name=${1} \
    --version ${2} \
    --approve
}

# Function to control scaling of cluster autoscalar
function scale_cluster_autoscalar(){
    kubectl scale deployments/cluster-autoscaler \
    --replicas=${1} \
    -n kube-system
}

# Function to upgrade autoscalar image
function upgrade_autoscalar_image(){
    kubectl -n kube-system \
    set image deployment.apps/cluster-autoscaler cluster-autoscaler=k8s.gcr.io/autoscaling/cluster-autoscaler:${1}
}

# Function to create static and dynamic nodegroups in EKS cluster
function create_nodegroups(){

    STATIC_NODEGROUP_INSTANCE_TYPE="m5.large"
    GPU_NODEGROUP_INSTANCE_TYPE="p3.16xlarge"
    INF_NODEGROUP_INSTANCE_TYPE="inf1.xlarge"
    INF_NODEGROUP_AMI="ami-092059396c7e51f52"
    
    # static nodegroup
    eksctl create nodegroup \
    --name static-nodegroup-${2/./-} \
    --cluster ${1} \
    --node-type ${STATIC_NODEGROUP_INSTANCE_TYPE} \
    --nodes 1 \
    --node-labels "static=true" \
    --tags "k8s.io/cluster-autoscaler/node-template/label/static=true" \
    --asg-access \
    --ssh-access \
    --ssh-public-key "${3}"

    # dynamic gpu nodegroup
    eksctl create nodegroup \
    --name gpu-nodegroup-${2/./-} \
    --cluster ${1} \
    --node-type ${GPU_NODEGROUP_INSTANCE_TYPE} \
    --nodes-min 0 \
    --nodes-max 100 \
    --node-volume-size 80 \
    --node-labels "test_type=gpu" \
    --tags "k8s.io/cluster-autoscaler/node-template/label/test_type=gpu" \
    --asg-access \
    --ssh-access \
    --ssh-public-key "${3}"

    # dynamic inf nodegroup
    eksctl create nodegroup \
    --name inf-nodegroup-${2/./-} \
    --cluster ${1} \
    --node-type ${INF_NODEGROUP_INSTANCE_TYPE} \
    --nodes-min 0 \
    --nodes-max 100 \
    --node-volume-size 500 \
    --node-ami ${INF_NODEGROUP_AMI} \
    --node-labels "test_type=inf" \
    --tags "k8s.io/cluster-autoscaler/node-template/label/test_type=inf,k8s.io/cluster-autoscaler/node-template/resources/aws.amazon.com/neuron=1" \
    --asg-access \
    --ssh-access \
    --ssh-public-key "${3}"
}

# Add or remove S3 access for GPU nodegroup worker nodes
function manage_s3_access_for_gpu_nodes(){
  NODE_GROUP_NAME="gpu-nodegroup-${2/./-}"

  INSTANCE_PROFILE_PREFIX=$(aws cloudformation describe-stacks | jq -r '.Stacks[].StackName' | grep ${NODE_GROUP_NAME})

  if [ -n "${INSTANCE_PROFILE_PREFIX}" ]; then
    INSTANCE_PROFILE_NAME=$(aws iam list-instance-profiles | jq -r '.InstanceProfiles[].InstanceProfileName' | grep $INSTANCE_PROFILE_PREFIX)
    if [ -n "${INSTANCE_PROFILE_NAME}" ]; then
      S3_POLICY_ARN="arn:aws:iam::aws:policy/AmazonS3FullAccess"
      ROLE_NAME=$(aws iam get-instance-profile --instance-profile-name $INSTANCE_PROFILE_NAME | jq -r '.InstanceProfile.Roles[] | .RoleName')
      
      if [ "$1" = "attach" ]; then
        aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn $S3_POLICY_ARN
      elif [ "$1" = "detach" ]
        aws iam detach-role-policy --role-name $ROLE_NAME --policy-arn $S3_POLICY_ARN
    else  
      echo "Instance Profile $INSTANCE_PROFILE_NAME does not exist for the $NODE_GROUP_NAME nodegroup"
    fi
  else
    echo "CloudFormation stack for $NODE_GROUP_NAME nodegroup does not exist"
  fi
}

# Function to delete all nodegroups in EKS cluster
function delete_nodegroups(){

    LIST_NODE_GROUPS=$(eksctl get nodegroup --cluster ${1} -o json | jq -r '.[].Name')

    if [ -n "${LIST_NODE_GROUPS}" ]; then
    
      for NODEGROUP in $LIST_NODE_GROUPS; do
        eksctl delete nodegroup \
        --name $NODEGROUP \
        --cluster ${1} \
        --region ${2}
      done
    else
      echo "No Nodegroups present in the EKS cluster ${1}"
    fi
}

# Function to upgrade nodegroups
function upgrade_nodegroups(){
    manage_s3_access_for_gpu_nodes "detach" ${2}
    delete_nodegroups ${1} ${3}
    create_nodegroups ${1} ${2} ${4}
    manage_s3_access_for_gpu_nodes "attach" ${2}
}

#Function to upgrade core k8s components
function update_eksctl_utils(){
    eksctl utils update-kube-proxy \
    --cluster ${1} \
    --region ${2} \
    --approve

    eksctl utils update-aws-node \
    --cluster ${1} \
    --region ${2} \
    --approve

    eksctl utils update-coredns \
    --cluster ${1} \
    --region ${2} \
    --approve
}

if [ $# -ne 3 ]; then
    echo "usage: ./${0} eks_cluster_name eks_version cluster_autoscalar_image_version"
    exit 1
fi

if [ -z "${AWS_REGION}" ]; then
  echo "AWS region not configured"
  exit 1
fi

if [ -z "${EKS_CLUSTER_MANAGER_ROLE}" ]; then
  echo "EKS cluster management role not set"
  exit 1
fi

CLUSTER=${1}
EKS_VERSION=${2}
CLUSTER_AUTOSCALAR_IMAGE_VERSION=${3}

if [ -z "${EC2_KEY_PAIR_NAME}" ]; then
  KEY_NAME=${CLUSTER}-KeyPair
  echo "No EC2 key pair name configured. Creating KeyPair ${KEY_NAME}"
  create_ec2_key_pair ${KEY_NAME}
  EC2_KEY_PAIR_NAME=${KEY_NAME}
else
  exist=$(aws ec2 describe-key-pairs --key-name ${EC2_KEY_PAIR_NAME} --region ${AWS_REGION} | grep KeyName | wc -l)
  if [ ${exist} -eq 0 ]; then
    echo "EC2 key pair ${EC2_KEY_PAIR_NAME} does not exist in ${AWS_REGION} region"
    exit 1
  fi
fi


update_kubeconfig ${CLUSTER} ${EKS_CLUSTER_MANAGER_ROLE} ${AWS_REGION}

#scale to 0 to avoid unwanted scaling
scale_cluster_autoscalar 0

upgrade_autoscalar_image ${CLUSTER_AUTOSCALAR_IMAGE_VERSION}
upgrade_eks_control_plane ${CLUSTER} ${EKS_VERSION}
upgrade_nodegroups ${CLUSTER} ${EKS_VERSION} ${AWS_REGION} ${EC2_KEY_PAIR_NAME}
update_eksctl_utils ${CLUSTER} ${AWS_REGION}

#scale back to 1
scale_cluster_autoscalar 1