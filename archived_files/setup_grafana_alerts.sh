#!/bin/bash
set -e

# Configuration - Use environment variables or prompt for credentials
VPS_IP="${VPS_IP:-23.88.125.23}"
VPS_USER="${VPS_USER:-root}"
VPS_PASSWORD="${VPS_PASSWORD:-}"  # Will prompt if not set
APP_DIR="/opt/job-scraper"
SSH_OPTS="-o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ConnectTimeout=30"

# Function to handle errors
handle_error() {
    echo "ERROR: $1"
    echo "The alert setup script encountered an error. Please fix the issue and try again."
    exit 1
}

echo "===================================================="
echo "Setting up Grafana Alerts for Job Scraper"
echo "===================================================="

# Prompt for VPS password if not set
if [ -z "$VPS_PASSWORD" ]; then
    echo -n "Enter VPS password for ${VPS_USER}@${VPS_IP}: "
    read -s VPS_PASSWORD
    echo ""
    if [ -z "$VPS_PASSWORD" ]; then
        handle_error "Password cannot be empty"
    fi
fi

# Function to run commands on the remote server
run_remote() {
    local max_retries=3
    local retry_count=0
    local cmd="$1"
    
    while [ $retry_count -lt $max_retries ]; do
        echo "  → Running command on remote server (attempt $((retry_count+1))/$max_retries)..."
        if sshpass -p "${VPS_PASSWORD}" ssh $SSH_OPTS ${VPS_USER}@${VPS_IP} "$cmd"; then
            return 0
        else
            echo "  → Command failed, retrying in 5 seconds..."
            retry_count=$((retry_count+1))
            sleep 5
        fi
    done
    
    echo "Error executing command on remote server after $max_retries attempts: $cmd"
    return 1
}

# Verify required tools are installed
command -v sshpass >/dev/null 2>&1 || handle_error "sshpass is required but not installed. Please install it with: sudo apt-get install sshpass"

# Create necessary directories
echo "Creating alert directories..."
run_remote "mkdir -p ${APP_DIR}/alert_rules" || handle_error "Failed to create alert directories"

# First, wait for Grafana to be fully up and running
echo "Waiting for Grafana to be ready..."
run_remote "i=0; while ! curl -s http://localhost:3000/api/health > /dev/null; do 
    echo 'Waiting for Grafana... (attempt '\$i'/30)'; 
    sleep 5; 
    i=\$((i+1)); 
    if [ \$i -ge 30 ]; then 
        echo 'Grafana failed to start after 150 seconds';
        exit 1;
    fi
done" || handle_error "Timed out waiting for Grafana to start"

# Set up notification channel for Grafana alerts (webhook)
echo "Setting up Slack notification channel..."
run_remote "curl -s -X POST -H 'Content-Type: application/json' -d '{
  \"name\": \"slack\",
  \"type\": \"slack\",
  \"settings\": {
    \"url\": \"https://hooks.slack.com/services/your-slack-webhook-url\",
    \"recipient\": \"#alerts\",
    \"mentionUsers\": \"\",
    \"mentionGroups\": \"\",
    \"mentionChannel\": \"here\",
    \"token\": \"your-slack-token\"
  },
  \"disableResolveMessage\": false,
  \"sendReminder\": true,
  \"frequency\": \"15m\"
}' -u admin:admin http://localhost:3000/api/alert-notifications" || echo "Warning: Failed to set up Slack notification channel. This can be configured manually in Grafana."

echo "Setting up email notification channel..."
run_remote "curl -s -X POST -H 'Content-Type: application/json' -d '{
  \"name\": \"email\",
  \"type\": \"email\",
  \"settings\": {
    \"addresses\": \"your-email@example.com\"
  },
  \"disableResolveMessage\": false
}' -u admin:admin http://localhost:3000/api/alert-notifications" || echo "Warning: Failed to set up email notification channel. This can be configured manually in Grafana."

# Create alert rules for common issues
echo "Creating alert rules..."

# Alert for high CPU usage
echo "Setting up alert for high CPU usage..."
run_remote "cat > ${APP_DIR}/alert_rules/high_cpu_usage.json << 'EOF'
{
  \"dashboard\": {
    \"annotations\": {
      \"list\": [
        {
          \"builtIn\": 1,
          \"datasource\": \"-- Grafana --\",
          \"enable\": true,
          \"hide\": true,
          \"iconColor\": \"rgba(0, 211, 255, 1)\",
          \"name\": \"Annotations & Alerts\",
          \"type\": \"dashboard\"
        }
      ]
    },
    \"editable\": true,
    \"gnetId\": null,
    \"graphTooltip\": 0,
    \"id\": null,
    \"links\": [],
    \"panels\": [
      {
        \"alert\": {
          \"alertRuleTags\": {},
          \"conditions\": [
            {
              \"evaluator\": {
                \"params\": [
                  80
                ],
                \"type\": \"gt\"
              },
              \"operator\": {
                \"type\": \"and\"
              },
              \"query\": {
                \"params\": [
                  \"A\",
                  \"5m\",
                  \"now\"
                ]
              },
              \"reducer\": {
                \"params\": [],
                \"type\": \"avg\"
              },
              \"type\": \"query\"
            }
          ],
          \"executionErrorState\": \"alerting\",
          \"for\": \"5m\",
          \"frequency\": \"1m\",
          \"handler\": 1,
          \"name\": \"High CPU Usage Alert\",
          \"noDataState\": \"no_data\",
          \"notifications\": [
            {
              \"uid\": \"slack\"
            },
            {
              \"uid\": \"email\"
            }
          ],
          \"message\": \"CPU usage has been over 80% for more than 5 minutes\"
        },
        \"aliasColors\": {},
        \"bars\": false,
        \"dashLength\": 10,
        \"dashes\": false,
        \"datasource\": \"Prometheus\",
        \"fill\": 1,
        \"fillGradient\": 0,
        \"gridPos\": {
          \"h\": 8,
          \"w\": 12,
          \"x\": 0,
          \"y\": 0
        },
        \"hiddenSeries\": false,
        \"id\": 2,
        \"legend\": {
          \"avg\": false,
          \"current\": false,
          \"max\": false,
          \"min\": false,
          \"show\": true,
          \"total\": false,
          \"values\": false
        },
        \"lines\": true,
        \"linewidth\": 1,
        \"nullPointMode\": \"null\",
        \"options\": {
          \"dataLinks\": []
        },
        \"percentage\": false,
        \"pointradius\": 2,
        \"points\": false,
        \"renderer\": \"flot\",
        \"seriesOverrides\": [],
        \"spaceLength\": 10,
        \"stack\": false,
        \"steppedLine\": false,
        \"targets\": [
          {
            \"expr\": \"job_scraper_cpu_usage * 100\",
            \"refId\": \"A\"
          }
        ],
        \"thresholds\": [
          {
            \"colorMode\": \"critical\",
            \"fill\": true,
            \"line\": true,
            \"op\": \"gt\",
            \"value\": 80
          }
        ],
        \"timeFrom\": null,
        \"timeRegions\": [],
        \"timeShift\": null,
        \"title\": \"CPU Usage\",
        \"tooltip\": {
          \"shared\": true,
          \"sort\": 0,
          \"value_type\": \"individual\"
        },
        \"type\": \"graph\",
        \"xaxis\": {
          \"buckets\": null,
          \"mode\": \"time\",
          \"name\": null,
          \"show\": true,
          \"values\": []
        },
        \"yaxes\": [
          {
            \"format\": \"percent\",
            \"label\": null,
            \"logBase\": 1,
            \"max\": null,
            \"min\": null,
            \"show\": true
          },
          {
            \"format\": \"short\",
            \"label\": null,
            \"logBase\": 1,
            \"max\": null,
            \"min\": null,
            \"show\": true
          }
        ],
        \"yaxis\": {
          \"align\": false,
          \"alignLevel\": null
        }
      }
    ],
    \"schemaVersion\": 22,
    \"style\": \"dark\",
    \"tags\": [],
    \"templating\": {
      \"list\": []
    },
    \"time\": {
      \"from\": \"now-6h\",
      \"to\": \"now\"
    },
    \"timepicker\": {},
    \"timezone\": \"\",
    \"title\": \"Job Scraper CPU Usage\",
    \"uid\": \"cpu\",
    \"version\": 1
  }
}
EOF" || handle_error "Failed to create CPU usage alert configuration"

# Import the alert dashboard to Grafana
echo "Importing CPU usage alert dashboard to Grafana..."
run_remote "curl -s -X POST -H 'Content-Type: application/json' -d @${APP_DIR}/alert_rules/high_cpu_usage.json -u admin:admin http://localhost:3000/api/dashboards/db || echo 'Failed to import dashboard, will continue with other alerts'" 

# Alert for scraper failures
echo "Setting up alert for scraper failures..."
run_remote "cat > ${APP_DIR}/alert_rules/scraper_failures.json << 'EOF'
{
  \"dashboard\": {
    \"annotations\": {
      \"list\": [
        {
          \"builtIn\": 1,
          \"datasource\": \"-- Grafana --\",
          \"enable\": true,
          \"hide\": true,
          \"iconColor\": \"rgba(0, 211, 255, 1)\",
          \"name\": \"Annotations & Alerts\",
          \"type\": \"dashboard\"
        }
      ]
    },
    \"editable\": true,
    \"gnetId\": null,
    \"graphTooltip\": 0,
    \"id\": null,
    \"links\": [],
    \"panels\": [
      {
        \"alert\": {
          \"alertRuleTags\": {},
          \"conditions\": [
            {
              \"evaluator\": {
                \"params\": [
                  5
                ],
                \"type\": \"gt\"
              },
              \"operator\": {
                \"type\": \"and\"
              },
              \"query\": {
                \"params\": [
                  \"A\",
                  \"5m\",
                  \"now\"
                ]
              },
              \"reducer\": {
                \"params\": [],
                \"type\": \"sum\"
              },
              \"type\": \"query\"
            }
          ],
          \"executionErrorState\": \"alerting\",
          \"for\": \"5m\",
          \"frequency\": \"1m\",
          \"handler\": 1,
          \"name\": \"Scraper Errors Alert\",
          \"noDataState\": \"no_data\",
          \"notifications\": [
            {
              \"uid\": \"slack\"
            },
            {
              \"uid\": \"email\"
            }
          ],
          \"message\": \"Job scraper has encountered more than 5 errors in the last 5 minutes\"
        },
        \"aliasColors\": {},
        \"bars\": false,
        \"dashLength\": 10,
        \"dashes\": false,
        \"datasource\": \"Prometheus\",
        \"fill\": 1,
        \"fillGradient\": 0,
        \"gridPos\": {
          \"h\": 8,
          \"w\": 12,
          \"x\": 0,
          \"y\": 0
        },
        \"hiddenSeries\": false,
        \"id\": 2,
        \"legend\": {
          \"avg\": false,
          \"current\": false,
          \"max\": false,
          \"min\": false,
          \"show\": true,
          \"total\": false,
          \"values\": false
        },
        \"lines\": true,
        \"linewidth\": 1,
        \"nullPointMode\": \"null\",
        \"options\": {
          \"dataLinks\": []
        },
        \"percentage\": false,
        \"pointradius\": 2,
        \"points\": false,
        \"renderer\": \"flot\",
        \"seriesOverrides\": [],
        \"spaceLength\": 10,
        \"stack\": false,
        \"steppedLine\": false,
        \"targets\": [
          {
            \"expr\": \"sum(increase(job_scraper_errors_total[5m]))\",
            \"refId\": \"A\"
          }
        ],
        \"thresholds\": [
          {
            \"colorMode\": \"critical\",
            \"fill\": true,
            \"line\": true,
            \"op\": \"gt\",
            \"value\": 5
          }
        ],
        \"timeFrom\": null,
        \"timeRegions\": [],
        \"timeShift\": null,
        \"title\": \"Scraper Errors\",
        \"tooltip\": {
          \"shared\": true,
          \"sort\": 0,
          \"value_type\": \"individual\"
        },
        \"type\": \"graph\",
        \"xaxis\": {
          \"buckets\": null,
          \"mode\": \"time\",
          \"name\": null,
          \"show\": true,
          \"values\": []
        },
        \"yaxes\": [
          {
            \"format\": \"short\",
            \"label\": null,
            \"logBase\": 1,
            \"max\": null,
            \"min\": null,
            \"show\": true
          },
          {
            \"format\": \"short\",
            \"label\": null,
            \"logBase\": 1,
            \"max\": null,
            \"min\": null,
            \"show\": true
          }
        ],
        \"yaxis\": {
          \"align\": false,
          \"alignLevel\": null
        }
      }
    ],
    \"schemaVersion\": 22,
    \"style\": \"dark\",
    \"tags\": [],
    \"templating\": {
      \"list\": []
    },
    \"time\": {
      \"from\": \"now-6h\",
      \"to\": \"now\"
    },
    \"timepicker\": {},
    \"timezone\": \"\",
    \"title\": \"Job Scraper Errors\",
    \"uid\": \"errors\",
    \"version\": 1
  }
}
EOF" || handle_error "Failed to create scraper failures alert configuration"

# Import the scraper failure alert dashboard to Grafana
echo "Importing scraper failures alert dashboard to Grafana..."
run_remote "curl -s -X POST -H 'Content-Type: application/json' -d @${APP_DIR}/alert_rules/scraper_failures.json -u admin:admin http://localhost:3000/api/dashboards/db || echo 'Failed to import dashboard, will continue with other alerts'"

echo "Setting up alert for no new jobs..."
run_remote "cat > ${APP_DIR}/alert_rules/no_new_jobs.json << 'EOF'
{
  \"dashboard\": {
    \"annotations\": {
      \"list\": [
        {
          \"builtIn\": 1,
          \"datasource\": \"-- Grafana --\",
          \"enable\": true,
          \"hide\": true,
          \"iconColor\": \"rgba(0, 211, 255, 1)\",
          \"name\": \"Annotations & Alerts\",
          \"type\": \"dashboard\"
        }
      ]
    },
    \"editable\": true,
    \"gnetId\": null,
    \"graphTooltip\": 0,
    \"id\": null,
    \"links\": [],
    \"panels\": [
      {
        \"alert\": {
          \"alertRuleTags\": {},
          \"conditions\": [
            {
              \"evaluator\": {
                \"params\": [
                  1
                ],
                \"type\": \"lt\"
              },
              \"operator\": {
                \"type\": \"and\"
              },
              \"query\": {
                \"params\": [
                  \"A\",
                  \"24h\",
                  \"now\"
                ]
              },
              \"reducer\": {
                \"params\": [],
                \"type\": \"sum\"
              },
              \"type\": \"query\"
            }
          ],
          \"executionErrorState\": \"alerting\",
          \"for\": \"12h\",
          \"frequency\": \"1h\",
          \"handler\": 1,
          \"name\": \"No New Jobs Alert\",
          \"noDataState\": \"no_data\",
          \"notifications\": [
            {
              \"uid\": \"slack\"
            },
            {
              \"uid\": \"email\"
            }
          ],
          \"message\": \"No new jobs have been collected in the last 24 hours\"
        },
        \"aliasColors\": {},
        \"bars\": false,
        \"dashLength\": 10,
        \"dashes\": false,
        \"datasource\": \"Prometheus\",
        \"fill\": 1,
        \"fillGradient\": 0,
        \"gridPos\": {
          \"h\": 8,
          \"w\": 12,
          \"x\": 0,
          \"y\": 0
        },
        \"hiddenSeries\": false,
        \"id\": 2,
        \"legend\": {
          \"avg\": false,
          \"current\": false,
          \"max\": false,
          \"min\": false,
          \"show\": true,
          \"total\": false,
          \"values\": false
        },
        \"lines\": true,
        \"linewidth\": 1,
        \"nullPointMode\": \"null\",
        \"options\": {
          \"dataLinks\": []
        },
        \"percentage\": false,
        \"pointradius\": 2,
        \"points\": false,
        \"renderer\": \"flot\",
        \"seriesOverrides\": [],
        \"spaceLength\": 10,
        \"stack\": false,
        \"steppedLine\": false,
        \"targets\": [
          {
            \"expr\": \"sum(increase(job_scraper_new_jobs_total[24h]))\",
            \"refId\": \"A\"
          }
        ],
        \"thresholds\": [
          {
            \"colorMode\": \"critical\",
            \"fill\": true,
            \"line\": true,
            \"op\": \"lt\",
            \"value\": 1
          }
        ],
        \"timeFrom\": null,
        \"timeRegions\": [],
        \"timeShift\": null,
        \"title\": \"New Jobs (24h)\",
        \"tooltip\": {
          \"shared\": true,
          \"sort\": 0,
          \"value_type\": \"individual\"
        },
        \"type\": \"graph\",
        \"xaxis\": {
          \"buckets\": null,
          \"mode\": \"time\",
          \"name\": null,
          \"show\": true,
          \"values\": []
        },
        \"yaxes\": [
          {
            \"format\": \"short\",
            \"label\": null,
            \"logBase\": 1,
            \"max\": null,
            \"min\": null,
            \"show\": true
          },
          {
            \"format\": \"short\",
            \"label\": null,
            \"logBase\": 1,
            \"max\": null,
            \"min\": null,
            \"show\": true
          }
        ],
        \"yaxis\": {
          \"align\": false,
          \"alignLevel\": null
        }
      }
    ],
    \"schemaVersion\": 22,
    \"style\": \"dark\",
    \"tags\": [],
    \"templating\": {
      \"list\": []
    },
    \"time\": {
      \"from\": \"now-7d\",
      \"to\": \"now\"
    },
    \"timepicker\": {},
    \"timezone\": \"\",
    \"title\": \"Job Scraper New Jobs\",
    \"uid\": \"newjobs\",
    \"version\": 1
  }
}
EOF" || handle_error "Failed to create no new jobs alert configuration"

# Import the no new jobs alert dashboard to Grafana
echo "Importing no new jobs alert dashboard to Grafana..."
run_remote "curl -s -X POST -H 'Content-Type: application/json' -d @${APP_DIR}/alert_rules/no_new_jobs.json -u admin:admin http://localhost:3000/api/dashboards/db || echo 'Failed to import dashboard, will continue with other alerts'"

# Verify alerts have been created
echo "Verifying alert configuration..."
run_remote "curl -s -H 'Content-Type: application/json' -u admin:admin http://localhost:3000/api/alerts | grep -q 'High CPU Usage Alert' || echo 'Warning: High CPU Usage Alert may not be configured properly'"
run_remote "curl -s -H 'Content-Type: application/json' -u admin:admin http://localhost:3000/api/alerts | grep -q 'Scraper Errors Alert' || echo 'Warning: Scraper Errors Alert may not be configured properly'"
run_remote "curl -s -H 'Content-Type: application/json' -u admin:admin http://localhost:3000/api/alerts | grep -q 'No New Jobs Alert' || echo 'Warning: No New Jobs Alert may not be configured properly'"

echo "===================================================="
echo "Grafana Alert Setup Complete!"
echo "===================================================="
echo
echo "The following alerts have been configured:"
echo "  1. High CPU Usage Alert - Triggers when CPU usage exceeds 80% for 5 minutes"
echo "  2. Scraper Errors Alert - Triggers when more than 5 errors occur in 5 minutes"
echo "  3. No New Jobs Alert - Triggers when no new jobs are collected for 24 hours"
echo
echo "You can view and modify these alerts in Grafana at:"
echo "  http://${VPS_IP}:3000 (login: admin/admin)"
echo
echo "Note: For Slack and email alerts to work properly, you need to"
echo "update the notification channel settings with your actual Slack webhook"
echo "URL and email addresses at http://${VPS_IP}:3000/alerting/notifications"
echo "====================================================" 