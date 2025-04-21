from setuptools import setup, find_packages

setup(
    name="ghalbir-blockchain",
    version="1.0.0",
    packages=find_packages(),
    install_requires=[
        "ecdsa",
        "flask",
        "cryptography",
        "web3",
    ],
    entry_points={
        'console_scripts': [
            'ghalbir-node=run_node:main',
            'ghalbir-api=run_api:main',
            'ghalbir-wallet=create_wallet:main',
            'ghalbir-mine=mine:main',
        ],
    },
    author="Ghalbir Team",
    author_email="info@ghalbir.com",
    description="Implementasi blockchain yang terinspirasi dari Ethereum",
    keywords="blockchain, ethereum, cryptocurrency",
    url="https://github.com/yourusername/ghalbir-blockchain",
    classifiers=[
        "Development Status :: 4 - Beta",
        "Intended Audience :: Developers",
        "License :: OSI Approved :: MIT License",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: Python :: 3.10",
    ],
    python_requires=">=3.8",
)
