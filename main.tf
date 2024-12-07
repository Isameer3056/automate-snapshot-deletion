terraform {
    required_version = ">=1.10.1"
    required_providers {
      aws = {
        source = "hashicorp/aws"
        version = "~>5.80.0"
      }
    }
    backend "s3" {
        bucket = "superuser-terraform-state-bucket"
        key    = "delete-inactive-snapshots/terraform.tfstate"
        region = "us-east-1"
        dynamodb_table = "superuser-terraform-state-locking"
    }
}
provider "aws" {
    region = var.aws_region
  
}

resource "aws_iam_role" "lambda_role" {
    name = "terraform_inactive_snapshots_delete_role"
    assume_role_policy = <<EOF
      {
    "Version": "2012-10-17",
    "Statement": [
        {
        "Action": "sts:AssumeRole",
        "Principal": {
            "Service": "lambda.amazonaws.com"
        },
        "Effect": "Allow",
        "Sid": ""
        }
    ]
    }
EOF
}

resource "aws_iam_policy" "iam_policy_for_lambda" {
    name = "terraform_inactive_snapshots_delete_policy"
    path = "/"
    policy = <<EOF
     {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": [
                    "logs:CreateLogGroup",
                    "logs:CreateLogStream",
                    "logs:PutLogEvents"
                ],
                "Resource": "arn:aws:logs:*:*:*"
            },
            {
                "Effect": "Allow",
                "Action": [
                    "ec2:DescribeVolumeStatus",
                    "ec2:DescribeSnapshots",
                    "ec2:DeleteSnapshot"
                ],
                "Resource": "*"
            }
        ]
        
    }
    EOF
}

resource "aws_iam_role_policy_attachment" "attach_iam_policy_to_iam_role" {
    role = aws_iam_role.lambda_role.name
    policy_arn = aws_iam_policy.iam_policy_for_lambda.arn
  
}

data "archive_file" "lambda_zip"{
    type = "zip"
    source_file = "${path.module}/python/snapshot-delete-script.py"
    output_path = "${path.module}/python/snapshot-delete-script.zip"
}

resource "aws_lambda_function" "lambda_function" {
    filename = "${path.module}/python/snapshot-delete-script.zip"
    function_name = "snapshot-delete-script"
    role = aws_iam_role.lambda_role.arn
    handler = "snapshot-delete-script.lambda_handler"
    runtime = "python3.12"
    timeout = 30
    depends_on = [ 
        aws_iam_role_policy_attachment.attach_iam_policy_to_iam_role 
    ]
}
resource "aws_cloudwatch_event_rule" "schedule_rule" {
    name = "inactive-snapshots-schedule-rule"
    description = "trigger lambda every day to delete the inactive snapshots"
    schedule_expression = "rate(24 hours)"
}

resource "aws_cloudwatch_event_target" "output" {
    rule = aws_cloudwatch_event_rule.schedule_rule.name
    arn = aws_lambda_function.lambda_function.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
    statement_id = "AllowExecutionFromEventBridge"
    action = "lambda:InvokeFunction"
    function_name = aws_lambda_function.lambda_function.function_name
    principal = "events.amazonaws.com"
    source_arn = aws_cloudwatch_event_rule.schedule_rule.arn
}

output "terraform_aws_role_output" {
    value = aws_iam_role.lambda_role.name
  
}

output "terraform_aws_lambda_role_arn_output" {
  value = aws_iam_role.lambda_role.arn
}