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
    branches = ["feature/gke-base-deployment", "feature/ha-scalability-hardening", "feature/risk-mitigation"]
    branch_diffs = analyze_branches(branches)
    
    # Calculate totals
    report = {
        "main": main_stats,
        "branches": {}
    }
    
    for branch, diffs in branch_diffs.items():
        # Start with main stats
        total_stats = main_stats.copy()
        has_changes = False
        for cat, changes in diffs.items():
            if changes['added'] > 0 or changes['deleted'] > 0:
                has_changes = True
            total_stats[cat] = total_stats.get(cat, 0) + changes['added'] - changes['deleted']
        
        # Only add branch if it has changes
        if has_changes:
            report['branches'][branch] = total_stats
    
    print(json.dumps(report, indent=2))
    
    generate_chart(report)

def generate_chart(report):
    try:
        import matplotlib.pyplot as plt
        import numpy as np
        
        # Prepare data: Main + Branches
        data = {'main': report['main']}
        data.update(report['branches'])
        
        branches = list(data.keys())
        categories = sorted(list({k for b in data.values() for k in b.keys()}))
        
        if not categories:
            print("No data to plot.")
            return

        x = np.arange(len(branches))
        width = 0.8 / len(categories)
        
        fig, ax = plt.subplots(figsize=(12, 6))
        
        for i, cat in enumerate(categories):
            vals = [data[b].get(cat, 0) for b in branches]
            offset = width * i
            rects = ax.bar(x + offset, vals, width, label=cat)
            
        ax.set_ylabel('Total Lines of Code (Log Scale)')
        ax.set_yscale('log')
        ax.set_title('Total Code Size by Branch and Category')
        ax.set_xticks(x + width * (len(categories) - 1) / 2)
        ax.set_xticklabels(branches, rotation=15, ha='right')
        ax.legend()
        
        plt.tight_layout()
        plt.savefig('branch_comparison.png')
        print("Chart saved to branch_comparison.png")
        
    except ImportError:
        print("matplotlib not found, skipping chart generation")
    except Exception as e:
        print(f"Error generating chart: {e}")

if __name__ == "__main__":
    main()
