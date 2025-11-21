import subprocess
import os
import json

CATEGORIES = {
    "Application Code": ["*.go", "templates/", "static/"],
    "IaC": ["terraform/", "k8s/", "Dockerfile", "docker-compose.yml"],
    "Database": ["init.sql", "migrations/"],
    "CI/CD": [".github/"],
    "Documentation": ["*.md", "docs/", "LICENSE"],
    "Scripts": ["scripts/"],
    "Config": [".env", "go.mod", "go.sum", ".gitignore"]
}

def get_category(filename):
    for cat, patterns in CATEGORIES.items():
        for pattern in patterns:
            if pattern.endswith("/"):
                if filename.startswith(pattern) or ("/" + pattern) in filename:
                    return cat
            elif pattern.startswith("*"):
                if filename.endswith(pattern[1:]):
                    return cat
            else:
                if filename == pattern or filename.endswith("/" + pattern):
                    return cat
    return "Other"

def run_command(cmd):
    return subprocess.check_output(cmd, shell=True).decode('utf-8').strip()

def analyze_main():
    print("Analyzing main branch...")
    files = run_command("git ls-tree -r main --name-only").split('\n')
    stats = {}
    
    for f in files:
        if not f: continue
        try:
            content = run_command(f"git show main:'{f}'")
            lines = len(content.split('\n'))
            cat = get_category(f)
            stats[cat] = stats.get(cat, 0) + lines
        except Exception as e:
            print(f"Error reading {f}: {e}")
            
    return stats

def analyze_branches(branches):
    branch_stats = {}
    for branch in branches:
        print(f"Analyzing branch {branch}...")
        try:
            # numstat gives: added deleted filename
            diff = run_command(f"git diff --numstat main...{branch}")
            stats = {}
            for line in diff.split('\n'):
                if not line: continue
                parts = line.split()
                if len(parts) < 3: continue
                added = int(parts[0]) if parts[0] != '-' else 0
                deleted = int(parts[1]) if parts[1] != '-' else 0
                filename = " ".join(parts[2:])
                
                cat = get_category(filename)
                # Store net change for now, we will calculate total later
                if cat not in stats:
                    stats[cat] = {'added': 0, 'deleted': 0}
                stats[cat]['added'] += added
                stats[cat]['deleted'] += deleted
            branch_stats[branch] = stats
        except Exception as e:
            print(f"Error analyzing branch {branch}: {e}")
    return branch_stats

def main():
    main_stats = analyze_main()
    # Only analyze gke-base-deployment (risk-mitigation is an earlier parallel branch)
    gke_base_stats = analyze_branches(["feature/gke-base-deployment"])
    
    # Calculate cumulative totals
    cumulative_stats = {}
    
    # Main baseline
    cumulative_stats["main"] = main_stats
    
    # GKE Base = Main + gke-base changes
    gke_cumulative = dict(main_stats)
    for cat, changes in gke_base_stats.get("feature/gke-base-deployment", {}).items():
        gke_cumulative[cat] = gke_cumulative.get(cat, 0) + changes['added'] - changes['deleted']
    cumulative_stats["feature/gke-base-deployment"] = gke_cumulative
    
    report = {
        "main": main_stats,
        "branches_delta": gke_base_stats,
        "cumulative": cumulative_stats
    }
    
    print(json.dumps(report, indent=2))
    
    generate_chart(report)

def generate_chart(report):
    try:
        import matplotlib.pyplot as plt
        import numpy as np
        
        # Use cumulative data for the chart - show progression: main -> gke-base
        branch_order = ["main", "feature/gke-base-deployment"]
        data = {k: report['cumulative'][k] for k in branch_order}
        
        branches = list(data.keys())
        # Rename for display
        branch_labels = ["Main", "GKE Base Deployment"]
        categories = sorted(list({k for b in data.values() for k in b.keys()}))
        
        if not categories:
            print("No data to plot.")
            return

        x = np.arange(len(branches))
        
        fig, ax = plt.subplots(figsize=(12, 7))
        
        # Create stacked bar chart
        bottom = np.zeros(len(branches))
        colors = plt.cm.Set3(np.linspace(0, 1, len(categories)))
        
        for i, cat in enumerate(categories):
            vals = [data[b].get(cat, 0) for b in branches]
            ax.bar(x, vals, label=cat, bottom=bottom, color=colors[i])
            bottom += vals
            
        ax.set_ylabel('Total Lines of Code', fontsize=12)
        ax.set_title('Cumulative Code Growth Across Branches', fontsize=14, fontweight='bold')
        ax.set_xticks(x)
        ax.set_xticklabels(branch_labels, fontsize=11)
        ax.legend(loc='upper left', fontsize=10)
        ax.grid(axis='y', alpha=0.3)
        
        # Add total labels on top of each bar
        for i, branch in enumerate(branches):
            total = sum(data[branch].values())
            ax.text(i, total, f'{total:,}', ha='center', va='bottom', fontweight='bold', fontsize=10)
        
        plt.tight_layout()
        plt.savefig('branch_comparison.png', dpi=150)
        print("Chart saved to branch_comparison.png")
        
    except ImportError:
        print("matplotlib not found, skipping chart generation")
    except Exception as e:
        print(f"Error generating chart: {e}")

if __name__ == "__main__":
    main()
